package Monitoring::Icinga2::Client::Mojo;

use strictures 2;
use Mojo::Base 'Mojo::UserAgent';
use Carp;
use Mojo::UserAgent;
use JSON;
use YAML::XS;   # TODO remove
use List::Util qw/ all any first /;
use constant DEBUG => $ENV{DEBUG};
our $VERSION = "v0.0.1";    # TODO

has 'url';
has api_version => sub { 1 };
has author => sub { getlogin || getpwuid($<) };

sub new {
    my $class = shift;
    my $self = $class->SUPER::new( max_response_size => 0, @_ );
    $self->transactor->name( __PACKAGE__ . ' ' . $VERSION );
    return $self;
}

sub i2req {
    my ( $self, $method, $path, $params, $data, $cb ) = @_;
    my $result_cb;
    # Any callback already receives the decoded body
    $cb and $result_cb = sub {
        $cb->( decode_json( $_[1]->result->body ) );
    };
    my $tx = $self->_start_i2req( $method, $path, $params, $data, $result_cb );

    return $tx if $cb;
    my $res = $tx->result;
    unless( $res->is_success ) {
        die $res->message;  # TODO Exception::Class
    }
    return $res->json;
}

sub _start_i2req {
    my ( $self, $method, $path, $params, $data, $result_cb, $streaming_cb ) = @_;

    my $url = $self->_urlobj;
    $path =~ s!^/!!;
    $url->path->merge( $path );
    $url->query->merge( @$params ) if defined $params;
    my $tx = $self->build_tx(
        $method,
        $url,
        { Accept => 'application/json' },
        ( $data ? (json => $data) : () )
    );
    if( defined $streaming_cb ) {
        $tx->res->content->unsubscribe( 'read' )->on(
            read => _callback_by_line( $streaming_cb ),
        );
    }
    return $self->start( $tx, $result_cb );
}

sub schedule_downtime {
    my $self = shift;
    my %objects = @_;
    delete @objects{qw/ start_time end_time comment author duration fixed callback /};
    return $self->schedule_downtimes( @_, objects => [ \%objects ] );
}

sub schedule_downtimes {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ start_time end_time comment objects /);
    # uncoverable condition true
    $args{author} //= $self->author;
    ref $args{objects} eq 'ARRAY' or croak("`objects' arg must be an arrayref");
    my $filters = $self->_create_downtime_filters( $args{objects} );
    say STDERR "FILTERS: ",Dump($filters);

    if( $args{callback} ) {
        my $delay = Mojo::IOLoop->delay;
        $self->_schedule_downtime_type( 'Host', $filters->{Host}, \%args,  sub { say STDERR "PASSCB1: ",Dump(\@_); $delay->pass(@_) } );
        $self->_schedule_downtime_type( 'Service', $filters->{Service}, \%args, sub { say STDERR "PASSCB2: ",Dump(\@_); $delay->pass(@_) } );
        return;
    }

    return [
        @{ $self->_schedule_downtime_type( 'Host', $filters->{Host}, \%args ) },
        @{ $self->_schedule_downtime_type( 'Service', $filters->{Service}, \%args ) },
    ];
}

sub _schedule_downtime_type {
    my ($self, $type, $filter, $args, $cb) = @_;
    return $cb->( [] ) unless $filter;
    return $self->_i2req_pd('POST',
        '/actions/schedule-downtime',
        {
            type => $type,
            joins => [ "host.name" ],
            filter => $filter,
            map { $_ => $args->{$_} } qw/ author start_time end_time comment duration fixed /
        },
        $cb,
    );
}

sub remove_downtime {
    my $self = shift;
    my %objects = @_;

    if( exists $objects{name} and defined $objects{name} ) {
        return $self->remove_downtimes( name => $objects{name} );
    }
    return $self->remove_downtimes( objects => [ \%objects ] );
}

sub remove_downtimes {
    my ($self, %args) = @_;

    if( defined $args{name} or defined $args{names} ) {
        # uncoverable condition false
        # uncoverable branch false
        my $names = $args{name} // $args{names};
        return $self->_i2req_pd('POST',
            "/actions/remove-downtime",
            {
                type => 'Downtime',
                filter => _filter_expr( 'downtime.__name', $names ),
            }
        );
    }

    ref $args{objects} eq 'ARRAY' or croak("`objects' arg must be an arrayref");
    my $filters = $self->_create_downtime_filters( $args{objects} );
    my @results;
    for my $type ( grep { $filters->{$_} } qw/ Host Service / ) {
        my $result = $self->_i2req_pd('POST',
            '/actions/remove-downtime',
            {
                type => $type,
                joins => [ "host.name" ],
                filter => $filters->{$type},
            }
        );
        push @results, @$result;
    }
    return \@results;
}


sub send_custom_notification {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ comment /);
    _checkargs_any(\%args, qw/ host service /);

    my $obj_type = defined $args{host} ? 'host' : 'service';

    return $self->_i2req_pd('POST',
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

sub set_notifications {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ state /);
    _checkargs_any(\%args, qw/ host service /);
    my $uri_object = $args{service} ? 'services' : 'hosts';

    return $self->_i2req_pd('POST',
        "/objects/$uri_object",
        {
            attrs => { enable_notifications => !!$args{state} },
            filter => _create_filter( \%args ),
        }
    );
}

sub query_app_attrs {
    my ($self) = @_;

    my $r = $self->_i2req_pd('GET',
        "/status/IcingaApplication",
    );
    # uncoverable branch true
    # uncoverable condition left
    # uncoverable condition right
    ref $r eq 'ARRAY' and defined $r->[0] and defined $r->[0]{status}{icingaapplication}{app} or die "Invalid result from Icinga";

    return $r->[0]{status}{icingaapplication}{app};
}

{
    my %legal_attrs = map { $_ => 1 } qw/
    event_handlers
    flapping
    host_checks
    notifications
    perfdata
    service_checks
    /;

    sub set_app_attrs {
        my ($self, %args) = @_;
        _checkargs_any(\%args, keys %legal_attrs);
        my @unknown_attrs = grep { not exists $legal_attrs{$_} } keys %args;
        @unknown_attrs and croak(
            sprintf "Unknown attributes: %s; legal attributes are: %s",
            join(",", sort @unknown_attrs),
            join(",", sort keys %legal_attrs),
        );

        return $self->_i2req_pd('POST',
            '/objects/icingaapplications/app',
            {
                attrs => {
                    map { 'enable_' . $_ => !!$args{$_} } keys %args
                },
            }
        );
    }
}

sub set_global_notifications {
    my ($self, $state) = @_;
    $self->set_app_attrs( notifications => $state );
}

sub query_hosts {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ hosts /);
    return $self->_i2req_pd( 'GET', '/objects/hosts',
        { filter => _filter_expr( "host.name", $args{hosts} ) },
        $args{callback},
    );
}

sub query_host {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ host /);
    my @callback;
    $args{callback} and @callback = ( callback => sub { $args{callback}->( shift->[0] ) } );
    my $res = $self->query_hosts( hosts => $args{host}, @callback);
    return $args{callback} ? $res : $res->[0];
}

sub query_child_hosts {
    my ($self, %args) = @_;
    _checkargs(\%args, qw/ host /);
    return $self->_i2req_pd( 'GET', '/objects/hosts',
        { filter => "\"$args{host}\" in host.vars.parents" }
    );
}

sub query_parent_hosts {
    my ($self, %args) = @_;
    my $expand = delete $args{expand};
    my $cb = delete $args{callback};
    if( $cb ) {
        # need to wrap callback for result unpacking/expansion
        my $wrapped_cb = $expand ?
        sub {
            my $parents = shift->{attrs}{vars}{parents};
            return $cb->( [] ) unless $parents;
            $self->query_hosts(
                hosts => shift->{attrs}{vars}{parents},
                callback => $cb,
            );
        } :
        sub { $cb->( shift->{attrs}{vars}{parents} // [] ) };
        return $self->query_host( %args, callback => $wrapped_cb );
    }
    # uncoverable condition right
    my $results = $self->query_host( %args ) // {};
    # uncoverable condition right
    my $names = $results->{attrs}{vars}{parents} // [];
    undef $results;
    # uncoverable condition right
    return $names unless $expand and @$names;
    return $self->query_hosts( hosts => $names );
}

sub query_services {
    my ($self, %args) = @_;
    _checkargs_any(\%args, qw/ service services /);
    my $srv = $args{service} // $args{services};
    return $self->_i2req_pd('GET', '/objects/services',
        { filter => _filter_expr( "service.name", $srv ) },
        $args{callback},
    );
}

sub query_downtimes {
    my ($self, %args) = @_;
    my $filter = _dtquery2filter( %args );
    return $self->_i2req_pd('GET', '/objects/downtimes',
        { $filter ? ( filter => $filter) : () }
    );
}

sub subscribe_events {
    my ($self, %args) = @_;

    require UUID;
    _checkargs(\%args, qw/ callback types /);
    return $self->_start_i2req('POST', '/events',
        [
            types => _validate_stream_types( $args{types} ),
            queue => $args{queue} // ( $self->author . '-' . uuid() ),
        ],
        undef,
        sub { $args{callback}->( decode_json(shift) ) },
    );
}

sub _validate_stream_types {
    my ($types) = @_;
    state $EVENT_STREAM_TYPES = {
        map { $_ => 1 } qw/ CheckResult StateChange Notification
        AcknowledgementSet AcknowledgementCleared CommentAdded CommentRemoved
        DowntimeAdded DowntimeRemoved DowntimeStarted DowntimeTriggered /
    };
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

# Send an Icinga2 request with postdata and return the results or transaction if async
sub _i2req_pd {
    my ($self, $method, $path, $postdata, $cb) = @_;

    $cb and return $self->i2req( $method, $path, undef, $postdata, sub { $cb->( _results_cb( shift ) ) } );
    return _results_cb( $self->i2req( $method, $path, undef, $postdata ) );
}

sub _results_cb {
    shift->{results} // croak( "Missing `results' field in Icinga response" );
}

sub _urlobj {
    my ($self) = @_;

    my $u = Mojo::URL->new( $self->url );
    $u->path->merge( 'v' . $self->api_version . '/' );
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
#
# From a callback coderef, create a new one that can be called with arbitrary
# chunks of text and will pass it on line by line to the original one.
sub _callback_by_line {
    my ($cb) = @_;
    my $acc;
    return sub {
        my $bytes = $_[1] // return;
        $acc .= $bytes;
        return unless $acc =~ /\n/;
        my @lines = split /^/, $acc, -1;
        $acc = pop @lines;
        $cb->( $_ ) for @lines;
    };
}

1;
