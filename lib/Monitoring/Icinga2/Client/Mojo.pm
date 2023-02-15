# ABSTRACT: Synchronous/asynchronous REST client for Icinga2

package Monitoring::Icinga2::Client::Mojo;

use v5.24;
use strictures 2;
use Mojo::Base 'Mojo::EventEmitter';
use Carp;
use Mojo::UserAgent;
use Mojo::Promise;
use Try::Tiny;
use JSON::MaybeXS qw/ decode_json /;
use Scalar::Util qw/ blessed /;
use List::Util qw/ all any first /;
use Sub::Quote qw/ quote_sub /;
use Monitoring::Icinga2::Client::Mojo::Downtime;
use Monitoring::Icinga2::Client::Mojo::Result;
use Monitoring::Icinga2::Client::Mojo::Transaction;
use namespace::clean;

our $EVENT_STREAM_TYPES = {
    AcknowledgementSet => [ qw/ host timestamp / ],
    AcknowledgementCleared => [ qw/ host timestamp / ],
    CheckResult => {
        host => 'shift->{host}',
        service => 'shift->{service}',
        timestamp => 'shift->{timestamp}',
        check_source => 'shift->{check_result}{check_source}',
        state => 'shift->{check_result}{state}',
        check_source => 'shift->{check_result}{check_source}',
    },
    CommentAdded => [ qw/ host timestamp / ],
    CommentRemoved => [ qw/ host timestamp / ],
    DowntimeAdded => {
        author => 'shift->{downtime}{author}',
        comment => 'shift->{downtime}{comment}',
        duration => 'shift->{downtime}{duration}',
        end_time => 'shift->{downtime}{end_time}',
        fixed => '!!shift->{downtime}{fixed}',
        host_name => 'shift->{downtime}{host_name}',
        legacy_id => 'shift->{downtime}{legacy_id}',
        name => 'shift->{downtime}{name}',
        service_name => 'shift->{downtime}{service_name}',
        start_time => 'shift->{downtime}{start_time}',
        timestamp => 'shift->{timestamp}',
        triggers => '[ @{ shift->{downtime}{triggers} // [] } ]',
        version => 'shift->{downtime}{version}',
        was_cancelled => '!!shift->{downtime}{was_cancelled}',
        zone => 'shift->{downtime}{zone}',
    },
    DowntimeRemoved => {
        author => 'shift->{downtime}{author}',
        comment => 'shift->{downtime}{comment}',
        duration => 'shift->{downtime}{duration}',
        end_time => 'shift->{downtime}{end_time}',
        fixed => '!!shift->{downtime}{fixed}',
        host_name => 'shift->{downtime}{host_name}',
        legacy_id => 'shift->{downtime}{legacy_id}',
        name => 'shift->{downtime}{name}',
        service_name => 'shift->{downtime}{service_name}',
        start_time => 'shift->{downtime}{start_time}',
        timestamp => 'shift->{timestamp}',
        triggers => '[ @{ shift->{downtime}{triggers} // [] } ]',
        version => 'shift->{downtime}{version}',
        was_cancelled => '!!shift->{downtime}{was_cancelled}',
        zone => 'shift->{downtime}{zone}',
    },
    DowntimeStarted => {
        host => 'shift->{host}',
        author => 'shift->{author}',
        service => 'shift->{service}',
        timestamp => 'shift->{timestamp}',
        text => 'shift->{text}',
        users => '[ @{ shift->{users} // [] } ]',
    },
    DowntimeTriggered => {
        author => 'shift->{downtime}{author}',
        comment => 'shift->{downtime}{comment}',
        duration => 'shift->{downtime}{duration}',
        host_name => 'shift->{downtime}{host_name}',
        legacy_id => 'shift->{downtime}{legacy_id}',
        name => 'shift->{downtime}{name}',
        service_name => 'shift->{downtime}{service_name}',
        timestamp => 'shift->{timestamp}',
        triggered_by => 'shift->{downtime}{triggered_by}',
        triggers => '[ @{ shift->{downtime}{triggers} // [] } ]',
    },
    Generic => [],
    Notification => {
        author => 'shift->{author}',
        host => 'shift->{host}',
        service => 'shift->{service}',
        timestamp => 'shift->{timestamp}',
        notification_type => 'shift->{notification_type}',
        text => 'shift->{text}',
        users => '[ @{ shift->{users} // [] } ]',
    },
    StateChange => [qw/ host service state state_type timestamp /],
};

has [qw/ ua url /];
has retries => sub { 0 };
has retry_delay => sub { 5 };
has api_version => sub { 1 };
has author => sub { getlogin || getpwuid($<) };
has icinga_events => sub { {} };

sub new {
    my $class = shift;
    my %args = @_ % 2 ? $_[0]->%* : @_;
    my $self = $class->SUPER::new(
        map { exists $args{$_} ? ( $_ => delete $args{$_} ) : () }
        qw/ ua url retries retry_delay api_version author /
    );
    my $ua = Mojo::UserAgent->new( max_response_size => 0 , %args )->insecure( !!delete $args{insecure} );
    $ua->transactor->name( __PACKAGE__ . ' ' . ( $Monitoring::Icinga2::Client::Mojo::VERSION // 'devel' ) );
    $self->ua( $ua );
    return $self;
}

sub i2req_p {
    my $self = shift;
    return $self->_start_i2req_p( @_ )->then(
        sub { decode_json( shift->result->body ) },
    );
}

sub query_p {
    my ($self, $path, $filter) = @_;
    return $self->_start_i2req_p( 'GET', $path, undef, [ $filter ] )->then(
        sub { decode_json( shift->result->body ) },
    );
}

sub schedule_downtime_p {
    my $self = shift;
    my %objects = @_;
    delete @objects{qw/ start_time end_time comment author duration fixed /};
    return $self->schedule_downtimes_p( @_, objects => [ \%objects ] );
}

sub schedule_downtimes_p {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ start_time end_time comment objects /);
    # uncoverable condition true
    $args{author} //= $self->author;
    ref $args{objects} eq 'ARRAY' or croak("`objects' arg must be an arrayref");
    my $filters = $self->_create_downtime_filters( $args{objects} );

    return Mojo::Promise->all(
        map { $self->_schedule_downtime_type( $_, $filters, \%args ) } qw/ Host Service /
    )->then(
        sub {
            my @results = @_;
            return [
                map { Monitoring::Icinga2::Client::Mojo::Downtime->new( $_ ) }
                map { @$_ } grep { defined } map { $results[$_][0] } $#results
            ]
        },
    );
}

sub _schedule_downtime_type {
    my ($self, $type, $filters, $args) = @_;
    return unless $filters->{$type};
    return $self->_i2req_pd_p('POST',
        '/actions/schedule-downtime',
        {
            type => $type,
            joins => [ "host.name" ],
            filter => $filters->{$type},
            map { $_ => $args->{$_} } qw/ author start_time end_time comment duration fixed /
        },
    );
}

sub remove_downtimes_p {
    my ($self, %args) = @_;
    my $p;

    if( defined $args{downtime} ) {
        my $filter;
        if( 'ARRAY' eq ref $args{downtime} ) {
            $filter = _filter_expr( 'downtime.__name', [ map { $_->name } @{ $args{downtime} } ] );
        } elsif(
            blessed($args{downtime})
                and $args{downtime}->isa( 'Monitoring::Icinga2::Client::Mojo::Downtime' ) ) {
            $filter = _filter_expr( 'downtime.__name', $args{downtime}->name );
        } else {
            croak( "downtime arg must be arrayref or Monitoring::Icinga2::Client::Mojo::Downtime object" );
        }
        $p = $self->_remove_downtime_type( 'Downtime', $filter );
    } elsif( defined $args{name} or defined $args{names} ) {
        $p = $self->_remove_downtime_type( 'Downtime',
            { Downtime => _filter_expr( 'downtime.__name', $args{name} // $args{names} ) }
        );
    } else {
        ref $args{objects} eq 'ARRAY'
            or croak("`objects' arg must be an arrayref");
        my $filters = $self->_create_downtime_filters( $args{objects} );
        my @results;
        $p = Mojo::Promise->all(
            map { $self->_remove_downtime_type( $_, $filters ) } qw/ Host Service /
        );
    }

    state $resolve = _make_resolve_cb( 'Result' );
    return $p->then( $resolve );
}

sub _make_resolve_cb {
    my ($resultclass) = @_;
    return sub {
        return [
            map {
                "Monitoring::Icinga2::Client::Mojo::$resultclass"->new( map { 'ARRAY' eq ref ? @$_ : $_ } @$_ )
            } @_
        ];
    };
}

sub _remove_downtime_type {
    my ($self, $type, $filters) = @_;
    state $joins = {
        Host => [ 'host.name' ],
        Service => [ 'host.name', 'service.name' ],
    };
    return unless $filters->{$type};
    return $self->_i2req_pd_p('POST',
        '/actions/remove-downtime',
        {
            type => $type,
            filter => $filters->{$type},
            $joins->{$type} ? ( joins => $joins->{$type} ) : (),
        }
    );
}

sub send_custom_notification_p {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ comment /);
    _checkargs_any(\%args, qw/ host service /);

    my $obj_type = defined $args{host} ? 'host' : 'service';

    return $self->_i2req_pd_p('POST',
        '/actions/send-custom-notification',
        {
            type => ucfirst $obj_type,
            filter => "$obj_type.name==\"$args{$obj_type}\"",
            comment => $args{comment},
            # uncoverable condition false
            # uncoverable branch right
            author => $args{author} // $self->author,
        }
    );
}

sub set_notifications_p {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ state /);
    _checkargs_any(\%args, qw/ host service /);
    my $uri_object = $args{service} ? 'services' : 'hosts';

    return $self->_i2req_pd_p('POST',
        "/objects/$uri_object",
        {
            attrs => { enable_notifications => !!$args{state} },
            filter => _create_filter( \%args ),
        }
    );
}

sub query_app_attrs_p {
    my ($self) = @_;

    return $self->_i2req_pd_p('GET', "/status/IcingaApplication",)->then(
       sub { shift->[0]{status}{icingaapplication}{app} }
    );
}

sub set_app_attrs_p {
    my ($self, %args) = @_;
    state $legal_attrs = {
        map { $_ => 1 } qw/ event_handlers flapping host_checks
        notifications perfdata service_checks /
    };

    _checkargs_any(\%args, keys %$legal_attrs);
    my @unknown_attrs = grep { not exists $legal_attrs->{$_} } keys %args;
    @unknown_attrs and croak(
        sprintf "Unknown attributes: %s; legal attributes are: %s",
        join(",", sort @unknown_attrs),
        join(",", sort keys %$legal_attrs),
    );

    return $self->_i2req_pd_p('POST',
        '/objects/icingaapplications/app',
        {
            attrs => {
                map { 'enable_' . $_ => !!$args{$_} } keys %args
            },
        }
    );
}

sub set_global_notifications_p {
    my ($self, $state) = @_;
    $self->set_app_attrs_p( notifications => $state );
}

sub query_host_p {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ host /);
    return $self->query_hosts_p( hosts => $args{host} )->then(
        sub { shift->[0] }
    );
}

sub query_hosts_p {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ hosts /);
    return $self->_i2req_pd_p( 'GET', '/objects/hosts',
        { filter => _filter_expr( "host.name", $args{hosts} ) },
    );
}

sub query_child_hosts_p {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ host /);
    return $self->_i2req_pd_p( 'GET', '/objects/hosts',
        { filter => "\"$args{host}\" in host.vars.parents" }
    );
}

sub query_parent_hosts_p {
    my ($self, %args) = @_;
    $args{hosts} //= delete $args{host};
    my $expand = delete $args{expand};
    my $p = $self->query_hosts_p( %args )->then(
        sub {
            my $r = shift->[0] // return [];
            my $parents = $r->{attrs}{vars}{parents} // [];
            return $parents unless $expand;
            return $self->query_hosts_p( hosts => $parents );
        }
    );
}

sub query_services_p {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ services /);
    return $self->_i2req_pd_p('GET', '/objects/services',
        { filter => _filter_expr( "service.name", $args{services} ) },
    );
}

sub query_downtimes_p {
    my ($self, %args) = @_;
    my $filter = _dtquery2filter( %args );
    return $self->_i2req_pd_p('GET', '/objects/downtimes',
        { $filter ? ( filter => $filter) : () }
    );
}

sub on {
    my ($self, $ev, $cb) = @_;
    my $ie = $self->icinga_events;

    my ($event, $filter) = split /:/, $ev, 2;
    my $filter_key = $filter // '';
    if( exists $EVENT_STREAM_TYPES->{$event} ) {
        if( $ie->{$filter_key}{$event} ) {
            $ie->{$filter_key}{$event}++;
        } else {
            $ie->{$filter_key}{$event}++;
            $self->_try_resubscribe_all( $ie->{$filter_key}, $filter );
        }
    }
    return $self->SUPER::on( $ev, $cb );
}

sub unsubscribe {
    my ($self, $ev, $cb) = @_;
    my $ie = $self->{icinga_events};

    my ($event, $filter) = split /:/, $ev, 2;
    my $filter_key = $filter // '';

    if( exists $EVENT_STREAM_TYPES->{$event} ) {
        if( 0 == --$ie->{$filter_key}{$event} ) {
            delete $ie->{$filter_key}{$event};
            $self->_try_resubscribe_all( $ie->{$filter_key}, $filter )
                or delete $ie->{$filter_key};
        }
    }
    return $self->SUPER::unsubscribe( $ev, $cb );
}

# Try to resubscribe to all events named as keys in %$ev and return a started transaction.
# If there are none, close the running transaction, delete the meta keys and return false.
sub _try_resubscribe_all {
    my ($self, $ev, $filter) = @_;

    my @events = grep { substr( $_, 0, 1 ) ne '_' } keys %$ev;
    if( @events ) {
        return $ev->{_running} = $self->_subscribe(
            \@events,
            $filter,
            $ev->{_queue} //= $self->_new_queue
        );
    }
    $ev->{_running}->closed if $ev->{_running};
    delete $ev->{_running};
    delete $ev->{_queue};
    return;
}

# Subscribe to a number of events sharing a filter expression
sub _subscribe {
    my ($self, $type, $filter, $queue) = @_;
    my @filter = defined $filter ? ( filter => $filter ) : ();

    weaken($self);
    my $tx = Monitoring::Icinga2::Client::Mojo::Transaction->new(
        $self->ua->build_tx(
            'POST',
            $self->_urlobj( '/events' ),
            { Accept => 'application/json' },
            json => {
                types => [ grep { substr($_,0,1) ne '_' } @$type ],
                @filter,
                queue => $queue,
            }
        ),
        $self->retries,
    );
    $tx->res->content->unsubscribe( 'read' )->on(
        read => _callback_by_line(
            sub {
                my $msg = decode_json(shift);
                $self->emit( $msg->{type} . (defined $filter ? ":$filter" : ""), _event_to_object( $msg ) );
            }
        )
    );
    $self->_start_retrying_p( $tx );
    return $tx;
}

# Create a new queue ID from author and UUID
sub _new_queue {
    my ($self) = @_;
    require UUID::Tiny;
    $self->author . '-' . UUID::Tiny::create_uuid_as_string(UUID::Tiny::UUID_V1());
}

sub _start_i2req_p {
    my ( $self, $method, $path, $params, $data, $streaming_cb ) = @_;
    my $tx = Monitoring::Icinga2::Client::Mojo::Transaction->new(
        $self->ua->build_tx(
            $method,
            $self->_urlobj( $path, $params ),
            { Accept => 'application/json' },
            @$data,
        ),
        $self->retries,
    );
    if( defined $streaming_cb ) {
        $tx->res->content->unsubscribe( 'read' )->on(
            read => _callback_by_line( $streaming_cb ),
        );
    }
    return $self->_start_retrying_p( $tx );
}

sub _start_retrying_p {
    my ($self, $tx, $promise) = @_;
    $promise //= Mojo::Promise->new;

    $self->ua->start_p( $tx )->then(
        sub { $promise->resolve( @_ ) },
        sub {
	        my $err = shift;
            my $retries_left = $tx->i2_retries or do {
                my $retries = $self->retries;
                $promise->reject(
                    $retries ? "$err (retried $retries times)" : $err
                );
                return;
            };
            $tx->i2_retries( $retries_left - 1 );
            weaken($tx);
            weaken($promise);
            weaken($self);
            Mojo::IOLoop->timer(
                $self->retry_delay => sub {
                    $self->_start_retrying_p( $tx, $promise )
                }
            );
        }
    );
    return $promise;
}

sub _event_to_object {
    my ($res) = @_;
    my $type = $res->{type};
    $type = 'Generic' unless exists $EVENT_STREAM_TYPES->{$type};
    return "Monitoring::Icinga2::Client::Mojo::Event::$type"->new( $res );
}

for my $method (qw/
    i2req query
    schedule_downtime schedule_downtimes remove_downtimes
    send_custom_notification set_notifications
    query_app_attrs set_app_attrs set_global_notifications
    query_hosts query_child_hosts query_parent_hosts
    query_services
    query_downtimes
    subscribe_events
    /) {
    quote_sub($method, sprintf(q{
            my $self=shift;
            my ($result, $error);
            $self->%s_p( @_ )->then(
                sub { $result = shift },
                sub { $error = shift }
            )->wait;
            die $error if defined $error;
            return $result;
            } , $method
        )
    );
}

sub _validate_stream_types {
    my ($types) = @_;
    our $EVENT_STREAM_TYPES;

    for( ref $types ) {
        $_ eq '' and $types = [ $types ], last;
        $_ eq 'ARRAY' and last;
        croak ( "`types' must be string or arrayref" );
    }
    my @invalid_types = grep { not exists $EVENT_STREAM_TYPES->{$_} } @$types;
    @invalid_types and croak(
        sprintf( "`types' must be one of %s, found %s",
            join( ", ", sort keys %$EVENT_STREAM_TYPES ),
            join( ", ", @invalid_types )
        )
    );
    return $types;
}

# Send an Icinga2 request with postdata and return a promise on the result
sub _i2req_pd_p {
    my ($self, $method, $path, $postdata) = @_;
    return $self->i2req_p( $method, $path, undef, [ json => $postdata ] )->then(
        sub { shift->{results} // croak( "Missing `results' field in Icinga response" ) }
    );
}

# Construct a Mojo::URL object using the $path fragment and GET $params
sub _urlobj {
    my ($self, $path, $params) = @_;

    my $u = Mojo::URL->new( $self->url );
    $path = "/$path" unless substr( $path, 0, 1) eq '/';
    $u->path->merge( 'v' . $self->api_version . $path );
    $u->query->merge( @$params ) if defined $params;
    return $u;
}

# Make sure that all keys are defined in the hash referenced by the first arg
sub _checkargs {
    my $args = shift;

    all { defined $args->{$_} } @_ or croak(
        sprintf "missing or undefined argument `%s' to %s()",
        ( first { not defined $args->{$_} } @_ ),
        (caller(1))[3]
    );
}

# Make sure at least one key is defined in the hash referenced by the first arg
sub _checkargs_any {
   my $args = shift;

   any { defined $args->{$_} } grep { exists $args->{$_} } @_ or croak(
       sprintf "need at least one argument of: %s to %s()",
       join(',', @_), (caller(1))[3]
   );
}

# Make sure at most one of the keys is defined in the hash referenced by the first arg
sub _checkargs_single {
    my $o = shift;
    1 < grep { defined $o->{$_} } @_
        and croak(sprintf(
            "only one of %s can be used at a time",
            join( ", ", @_)
        ));
}

# Create a simple filter for a hostname in $args->{host} and optionally a
# service name in $args->{service}
sub _create_filter {
    my $args = shift;
    defined $args->{host} or croak(
        sprintf( "missing or undefined argument `host' to %s()", (caller(1))[3] )
    );
    my $filter = _filter_expr( "host.name", $args->{host} );
    return $filter unless $args->{service};
    return "(($filter)&&(" . _filter_expr( "service.name", $args->{service} ) . '))';
}

# Builds up to two complex filter expressions from a list of downtime object hashes,
# returned under the keys "Host" and/or "Service" in a hashref.
sub _create_downtime_filters {
    my ($self, $objects) = @_;
    my @filters = map { _dtobj2filter( $_ ) } @$objects;
    return {
        map { _disjunction( $_, @filters ) } qw/ host service /
    };
}

# Builds an OR-expression from individual filter expessions as returned by _obj2filter()
# given that they match the type ("host"/"service") passed as first argument
sub _disjunction {
    my $type = shift;
    my %unique_filters = map { $_->{filter} => 1 } grep { $_->{type} eq $type } @_;
    return unless %unique_filters;
    return ucfirst( $type ) => join( "||", sort keys %unique_filters );
}

# Turns a hashref describing a downtime-specific filter into an Icinga2
# filter expression
sub _dtobj2filter {
    my ($o) = @_;
    ref $o eq 'HASH' or croak("filter definition must be a hash");
    _checkargs_single( $o, qw/ host hostglob hostre / );
    _checkargs_single( $o, qw/ service serviceglob servicere services / );
    my $ex_host = _typeexpr('host', $o );
    my $ex_serv = _typeexpr('service', $o );

    my @result;
    if( $ex_host and not $ex_serv ) {
        # This filters for a host object, plus potentially some services if
        # 'services' is set. In the latter case we need two queries
        push @result, { type => 'host', filter => $ex_host };
        push @result, { type => 'service', filter => $ex_host } if $o->{services};
    } else {
        unless( defined $ex_serv ) {
            my $filter_text = join(',', map { "$_ => $o->{$_}" } sort keys %$o);
            croak( "neither host nor service definition found in filter: $filter_text" );
        }
        push @result, {
            type => 'service',
            filter => ( $ex_host ? "($ex_host&&$ex_serv)" : $ex_serv )
        };
    }
    return @result; 
}

# Turn a downtime query into a filter expression
sub _dtquery2filter {
    my %q = @_;
    my @exprs;
    # allow host/service as aliases for host_name/service_name
    exists $q{$_} and $q{$_.'_name'} = delete $q{$_} for qw/ host service /;
    for my $attr ( qw/ host_name service_name author / ) {
        defined $q{$attr}         and push @exprs, '(' . _filter_expr( "downtime.$attr", $q{$attr} ) .')';
        defined $q{$attr.'_glob'} and push @exprs, "match(\"$q{$attr.'_glob'}\",downtime.$attr)";
        defined $q{$attr.'_re'}   and push @exprs, "regex(\"$q{$attr.'_re'}\",downtime.$attr)";
    }
    for my $attr ( qw/ start_time end_time duration entry_time / ) {
        defined $q{$attr.'_lt'} and push @exprs, "(downtime.$attr<$q{$attr.'_lt'})";
        defined $q{$attr.'_gt'} and push @exprs, "(downtime.$attr>$q{$attr.'_gt'})";
        defined $q{$attr}       and push @exprs, "(downtime.$attr==$q{$attr})";
    }
    defined $q{fixed} and push @exprs, "(downtime.fixed)";
    return join( "&&", @exprs );
}

# Returns a single host or service filter expression based on a description hash
# and the required type
sub _typeexpr {
    my ($type, $o) = @_;
    defined $o->{$type}        and return '(' . _filter_expr( "$type.name", $o->{$type} ) .')';
    defined $o->{$type.'glob'} and return "match(\"$o->{$type.'glob'}\",$type.name)";
    defined $o->{$type.'re'}   and return "regex(\"$o->{$type.'re'}\",$type.name)";
    return;
}

# Return an == or `in' expression depending on the type of argument.
# Only scalars and arrayrefs make sense!
sub _filter_expr {
    my ($type, $arg) = @_;
    return "$type==\"$arg\"" unless ref $arg;
    return "$type in [" . join( ',', map { "\"$_\"" } @$arg ) . ']';
}

# From a callback coderef, create a new one that can be called with arbitrary
# chunks of text and will pass it on line by line to the original one.
sub _callback_by_line {
    my ($cb) = @_;
    my $acc;
    return sub {
        my $bytes = $_[1] // return;
        $acc .= $bytes;
        return unless $acc =~ /\n/;
        # split into arbitrarily many fields while preserving trailing empty ones
        my @lines = split /^/, $acc, -1;
        $acc = pop @lines;
        $cb->( $_ ) for @lines;
    };
}

# Create Monitoring::Icinga2::Client::Mojo::Event subclasses for each
# event stream type
while( my ($subclass, $desc) = each %$EVENT_STREAM_TYPES ) {
    my $class = "Monitoring::Icinga2::Client::Mojo::Event::$subclass";
    ref $desc eq 'ARRAY'
        and $desc = { map { $_ => "shift->{$_}" } @$desc };

    quote_sub( "${class}::new" => q{
        my ($class, $pkt) = @_;
        return bless $pkt, $class;
        }
    );
    while( my ($method, $code) = each %$desc ) {
        quote_sub( "${class}::$method" => $code );
    }
}

1;
