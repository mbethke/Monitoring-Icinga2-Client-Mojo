#!/usr/bin/perl
use strict;
use warnings;
use v5.10.1;
use utf8;
use open qw/ :encoding(UTF-8) :std /;
use Test2::Bundle::More;
use Test2::Tools::Subtest qw/subtest_buffered/;
use Test::Builder;
use Test::Fatal;
use JSON::XS;
use Monitoring::Icinga2::Client::Mojo;
BEGIN { Monitoring::Icinga2::Client::Mojo::Tester->import }

my $LOGIN = getlogin || getpwuid($<);
my @START_END = (
    start_time => 1_234_567_890,
    end_time   => 1_234_567_890 + 60,
);

sub _downtime_query {
    my ($filter) = @_;
    my $common1 = '{"author":"admin","comment":"no comment","duration":null,"end_time":1234567950,';
    my $common2 = '"fixed":null,"joins":["host.name"],"start_time":1234567890,';
    return (
        $common1 . "\"filter\":\"$filter\"," . $common2 . '"type":"Host"}',
        $common1 . "\"filter\":\"$filter\"," . $common2 . '"type":"Service"}',
        $common1 . "\"filter\":\"($filter&&(service.name==\\\"myservice\\\"))\"," . '"fixed":null,"joins":["host.name"],"start_time":1234567890,"type":"Service"}',
    );
}

my $uri_base     = 'https://localhost:5665/v1';
my $uri_scheddt  = "$uri_base/actions/schedule-downtime";
my $uri_removedt = "$uri_base/actions/remove-downtime";
my $uri_custnot  = "$uri_base/actions/send-custom-notification";
my $uri_hosts    = "$uri_base/objects/hosts";
my $uri_services = "$uri_base/objects/services";
my $uri_downtimes= "$uri_base/objects/downtimes";
my $uri_app      = "$uri_base/objects/icingaapplications/app";
my $uri_status   = "$uri_base/status/IcingaApplication";

my $fil_host     = '"filter":"(host.name==\"localhost\")"';
my $fil_hostsrv  = '"filter":"((host.name==\"localhost\")&&(service.name==\"myservice\"))"';

sub test_schedule_downtime {
    my ( $host, $filter, $text ) = @_;
    my ( $req_dthost, $req_dtservs, $req_dtserv ) = _downtime_query( $filter );
    (my $req_dthostu = $req_dthost) =~ s/admin/$LOGIN/;

    req_ok(
        'schedule_downtime',
        [ host => $host, @START_END, comment => 'no comment', author => 'admin', ],
        [ $uri_scheddt => $req_dthost ],
        "schedule_downtime, $text"
    );

    req_ok(
        'schedule_downtime',
        [ host => $host, @START_END, comment => 'no comment', author => 'admin', services => 1 ],
        [
            $uri_scheddt => $req_dthost,
            $uri_scheddt => $req_dtservs,
        ],
        "schedule_downtime w/services, $text"
    );

    req_ok(
        'schedule_downtime',
        [ host => $host, @START_END, comment => 'no comment', author => 'admin', service => 'myservice' ],
        [ $uri_scheddt => $req_dtserv ],
        "schedule_downtime w/single service, $text"
    );

    req_ok(
        'schedule_downtime',
        [ host => $host, @START_END, comment => 'no comment' ],
        [ $uri_scheddt => $req_dthostu ],
        "schedule_downtime w/o explicit author, $text"
    );
}

sub test_schedule_downtimes {
    my ( $req_dthost ) = _downtime_query( 'match(\"db*\",host.name)||regex(\"web-[0-3]\",host.name)' );
    my ( undef, $req_dtservs ) = _downtime_query(
        '((host.name in [\"h3\",\"h4\"])&&(service.name==\"s3\"))||' .
        '((host.name==\"h2\")&&(service.name==\"s2\"))||'.
        '(service.name==\"s4\")||'.
        'match(\"db*\",host.name)'
    );
    my $objects = [
        { hostre => 'web-[0-3]' },
        { hostglob => 'db*', services => 1 },
        { host => 'h2', service => 's2' },
        { host => ['h3','h4'], service => 's3' },
        { service => 's4' },
    ];

    req_ok(
        'schedule_downtimes',
        [ objects => $objects, @START_END, comment => 'no comment', author => 'admin', ],
        [
            $uri_scheddt => $req_dthost,
            $uri_scheddt => $req_dtservs,
        ],
        "schedule_downtimes"
    );

    req_fail(
        'schedule_downtimes',
        [ objects => "foo", @START_END, comment => 'no comment', author => 'admin', ],
        qr/^`objects' arg must be an arrayref/,
        "catches wrong type of objects argument"
    );

    req_fail(
        'schedule_downtimes',
        [ objects => [ { host => 'foo' }, 'foo' ], @START_END, comment => 'no comment', author => 'admin', ],
        qr/^filter definition must be a hash/,
        "catches bad object definitions"
    );

    req_fail(
        'schedule_downtimes',
        [ objects => [ { host => 'foo', hostglob => 'bar*' } ], @START_END, comment => 'no comment', author => 'admin', ],
        qr/^only one of host, hostglob, hostre can be used at a time/,
        "catches incompatible args in objects"
    );

    req_fail(
        'schedule_downtimes',
        [ objects => [ { services => 1 } ], @START_END, comment => 'no comment', author => 'admin', ],
        qr/^neither host nor service definition found in filter/,
        "catches empty filter expressions"
    );
}


sub test_remove_downtime {
    req_fail(
        'remove_downtimes',
        [ objects => "foo", ],
        qr/^`objects' arg must be an arrayref/,
        "catches wrong type of objects argument"
    );

    req_ok(
        'remove_downtime',
        [ host => 'localhost', service => 'myservice' ],
        [ $uri_removedt => '{' . $fil_hostsrv . ',"joins":["host.name","service.name"],"type":"Service"}' ],
        "remove_downtime w/single service"
    );

    req_ok(
        'remove_downtime',
        # pass undef name to exercise another branch
        [ host => 'localhost', name => undef ],
        [ $uri_removedt => '{' . $fil_host . ',"joins":["host.name"],"type":"Host"}' ],
        "remove_downtime w/host only"
    );

    req_ok(
        'remove_downtime',
        [ name => 'foobar' ],
        [ $uri_removedt => '{"filter":"downtime.__name==\"foobar\"","type":"Downtime"}' ],
        "remove_downtime by name"
    );

    req_ok(
        'remove_downtime',
        [ name => [ qw/ foo bar / ] ],
        [ $uri_removedt => '{"filter":"downtime.__name in [\"foo\",\"bar\"]","type":"Downtime"}' ],
        "remove_downtimes by name"
    );

    req_ok(
        'remove_downtimes',
        [ names => 'foobar' ],
        [ $uri_removedt => '{"filter":"downtime.__name==\"foobar\"","type":"Downtime"}' ],
        "remove_downtimes by names (synonymous to name)"
    );
}

sub test_query_downtimes {
    my %lt_gt_eq = ( _lt => '<', _gt => '>', '' => '==' );
    my @tests = (
        [ ] => '{}',
        [ fixed => 1 ]                  => '{"filter":"(downtime.fixed)"}',
        [ host_name => 'h' ]            => '{"filter":"(downtime.host_name==\"h\")"}',
        [ host_name_glob => '*t' ]      => '{"filter":"match(\"*t\",downtime.host_name)"}',
        [ host_name_re => 'h.*t' ]      => '{"filter":"regex(\"h.*t\",downtime.host_name)"}',
        [ service_name => 's' ]         => '{"filter":"(downtime.service_name==\"s\")"}',
        [ service_name_glob => '*e' ]   => '{"filter":"match(\"*e\",downtime.service_name)"}',
        [ service_name_re => 's.*e' ]   => '{"filter":"regex(\"s.*e\",downtime.service_name)"}',
        [ author => 'a' ]               => '{"filter":"(downtime.author==\"a\")"}',
        [ author_glob => '*r' ]         => '{"filter":"match(\"*r\",downtime.author)"}',
        [ author_re => 'a.*r' ]         => '{"filter":"regex(\"a.*r\",downtime.author)"}',
    ); 
    while( my ($suffix, $sym) = each %lt_gt_eq ) {
        push @tests, (
            [ "start_time$suffix" => 12345678 ]      => '{"filter":"(downtime.start_time'.$sym.'12345678)"}',
            [ "end_time$suffix" => 12345678 ]        => '{"filter":"(downtime.end_time'.$sym.'12345678)"}',
            [ "duration$suffix" => 42 ]              => '{"filter":"(downtime.duration'.$sym.'42)"}',
            [ "entry_time$suffix" => 12345678 ]      => '{"filter":"(downtime.entry_time'.$sym.'12345678)"}',
        );
    }
    @tests % 2 and die 'BUG: odd number of elements in @tests';
    while(@tests) {
        my ($arg_ar, $result) = splice @tests, 0, 2;
        @$arg_ar % 2 and die 'BUG: odd number of elements in arguments array "'.join(', ', @$arg_ar).'"';
        my %args = @$arg_ar;
        req_ok(
            'query_downtimes',
            [ %args ],
            [ $uri_downtimes => $result ],
            "query downtime by " . join('/', keys %args),
        );
    }
}

sub test_downtimes {
    req_fail(
        'schedule_downtime',
        [ host => 'localhost' ],
        qr/^missing or undefined argument `start_time'/,
        "detects missing args"
    );

    test_schedule_downtime( 'localhost', '(host.name==\"localhost\")', "single host" );
    test_schedule_downtime( [ 'localhost', 'otherhost' ], '(host.name in [\"localhost\",\"otherhost\"])', "multiple hosts" );
    test_schedule_downtimes();
    test_remove_downtime();
    test_query_downtimes();
}

# Need more sophisticated Mojo::UserAgent::start spoofing for this to actually work
#sub test_async_sync {
#    my ( $r1, $r2 );
#    my @args = ( services => [ qw/ myservice otherservice / ] );
#    my $o = newob();
#    $r1 = $o->query_services( @args );
#    $o->query_services( @args, callback => sub {
#            shift->ioloop->stop;
#            $tx = shift;
#            say STDERR "CALLBACK called: $tx";
#            $r2 = $tx->result->json;
#        }
#    );
#    Mojo::IOLoop->start;
#    is_deeply( $r1, $r2, "Sync and async interfaces work the same" );
#    use YAML::XS; say STDERR " SYNC: ",Dump($r1);
#    use YAML::XS; say STDERR "ASYNC: ",Dump($r2);
#}

isa_ok( newob(), 'Monitoring::Icinga2::Client::Mojo', "new" );

test_downtimes();

req_ok(
    'send_custom_notification',
    [ comment => 'mycomment', author => 'admin', host => 'localhost' ],
    [ $uri_custnot => '{"author":"admin","comment":"mycomment","filter":"host.name==\"localhost\"","type":"Host"}' ],
    "send custom notification for host"
);

req_ok(
    'send_custom_notification',
    [ comment => 'mycomment', author => 'admin', service => 'myservice' ],
    [ $uri_custnot => '{"author":"admin","comment":"mycomment","filter":"service.name==\"myservice\"","type":"Service"}' ],
    "send custom notification for service"
);

req_ok(
    'send_custom_notification',
    [ comment => 'mycomment', service => 'myservice' ],
    [ $uri_custnot => '{"author":"' . $LOGIN . '","comment":"mycomment","filter":"service.name==\"myservice\"","type":"Service"}', ],
    "send custom notification w/o explicit author"
);

req_ok(
    'set_notifications',
    [ state => 1, host => 'localhost' ],
    [ $uri_hosts => '{"attrs":{"enable_notifications":1},"filter":"host.name==\"localhost\""}' ],
    "enable notifications for host"
);

req_ok(
    'set_notifications',
    [ state => 0, host => 'localhost', service => 'myservice' ],
    [ $uri_services => '{"attrs":{"enable_notifications":""},'. $fil_hostsrv .'}' ],
    "disable notifications for service"
);

req_fail(
    'set_notifications',
    [ state => 1, service => 'myservice' ],
    qr/^missing or undefined argument `host' to Monitoring::Icinga2::Client::Mojo::set_notifications()/,
    "catches missing host argument"
);

req_fail(
    'set_notifications',
    [ ],
    qr/^missing or undefined argument `state'/,
    "catches missing state"
);

req_ok(
    'query_app_attrs',
    [ ],
    [ $uri_status => '' ],
    "query application attributes"
);

req_ok(
    'set_app_attrs',
    [ flapping => 1, notifications => 0, perfdata => 1 ],
    [ $uri_app => '{"attrs":{"enable_flapping":1,"enable_notifications":"","enable_perfdata":1}}' ],
    "set application attributes"
);

req_fail(
    'set_app_attrs',
    [ foo => 1 ],
    qr/^need at least one argument of/,
    "detects missing valid args"
);

req_fail(
    'set_app_attrs',
    [ foo => 1, notifications => 0, bar => 'qux' ],
    qr/^Unknown attributes: bar,foo; legal attributes are: event_handlers,/,
    "detects invalid arg"
);

req_ok(
    'set_global_notifications',
    [ 1 ],
    [ $uri_app => '{"attrs":{"enable_notifications":1}}' ],
    "enable global notifications"
);

req_ok(
    'query_hosts',
    [ hosts => [qw/ localhost otherhost /] ],
    [ $uri_hosts => '{"filter":"host.name in [\"localhost\",\"otherhost\"]"}' ],
    "query host"
);

req_ok(
    'query_host',
    [ host => 'localhost' ],
    [ $uri_hosts => '{"filter":"host.name==\"localhost\""}' ],
    "query host"
);

req_ok(
    'query_child_hosts',
    [ host => 'localhost' ],
    [ $uri_hosts => '{"filter":"\"localhost\" in host.vars.parents"}' ],
    "query child hosts"
);

req_ok(
    'query_parent_hosts',
    [ host => 'localhost' ],
    [ $uri_hosts => '{"filter":"host.name==\"localhost\""}' ],
    "query parent hosts"
);

## TODO: find out why this fails. Works fine without mockups.
#req_ok(
#    'query_parent_hosts',
#    [ host => 'localhost', expand => 1 ],
#    [
#        $uri_hosts => '{"filter":"host.name==\"localhost\""}',
#        $uri_hosts => '{"filter":"host.name in [\"parent1\",\"parent2\"]"}'
#    ],
#    "query parent hosts with expansion"
#);

req_ok(
    'query_services',
    [ service => 'myservice' ],
    [ $uri_services => '{"filter":"service.name==\"myservice\""}' ],
    "query service"
);

req_ok(
    'query_services',
    [ services => [ qw/ myservice otherservice / ] ],
    [ $uri_services => '{"filter":"service.name in [\"myservice\",\"otherservice\"]"}' ],
    "query services (synonymous arg)"
);

# Check that _mic_author is always set
is( newob()->author, $LOGIN, "author set with useragent" );
is( Monitoring::Icinga2::Client::Mojo->new( url => 'localhost' )->author, $LOGIN, "author set w/o useragent" );

#test_async_sync();

done_testing;

# Check that a request succeeds and has both the right URI and the
# correct postdata.
# Args:
# * method to call
# * arguments as an arrayref
# * expected requests as uri => postdata pairs in a an arrayref
# * description of this test
sub req_ok {
    my ($method, $margs, $req_cont, $desc) = @_;
    my $c = newob();
    is(
        exception { $c->$method( @$margs ) },
        undef,
        "$desc: arg check passes for $method",
    ) and _checkreq( $c, $req_cont, $desc );
}

# Check that a request fails (i.e. dies) when it is supposed to,
# e.g. to catch wrong or missing arguments
sub req_fail {
    my ($method, $margs, $except_re, $desc) = @_;
    my $c = newob();
    like(
        exception { $c->$method( @$margs ) },
        $except_re,
        "$method fails: $desc",
    );
}

sub _checkreq {
    my ($c, $req_contents, $desc) = @_;
    my @requests = grep { $_->{method} eq 'Monitoring::Icinga2::Client::Mojo::Tester::start' } @{ $c->calls };
    @$req_contents % 2 and die "BUG: odd number of request elements for `$desc' test";
    my $nreqs_needed = @$req_contents / 2;
    is(
        0+@requests,
        $nreqs_needed,
        sprintf(
            "%s: made %d REST call%s",
            $desc, $nreqs_needed, $nreqs_needed > 1 ? 's' : ''
        )
    );

    my $i = 1;
    for my $req ( @requests ) {
        my $r = $req->{args}[0]->req;
        my ($uri, $content) = splice @$req_contents, 0, 2 or last;
        like( $r->url, qr/^$uri$/, "$desc (uri $i)" );
        is( _canon_json( $r->body ), $content, "$desc (req $i)" );
        $i++;
    }
}

# Construct a new object with the subclassed user agent that collects call stats
sub newob {
    return Monitoring::Icinga2::Client::Mojo::Tester->new->url('https://localhost:5665/');
}

# Canonicalize a JSON string by decoding and subsequent encoding
sub _canon_json {
    my $s = shift;
    return $s unless defined $s and length $s;
    my $codec = JSON::XS->new->canonical;
    return $codec->encode(
        $codec->decode( $s )
    );
}

{
    package Monitoring::Icinga2::Client::Mojo::Tester;
    use Mojo::Base 'Monitoring::Icinga2::Client::Mojo';
    use Clone 'clone';

    sub start {
        my $self = shift;
        $self->_logcall( @_ );
        my $tx = shift;
        my $content = '{"results":["dummy"]}';

        if( $tx->isa('Mojo::Transaction::HTTP') ) {
            if( $tx->req->url->path eq '/v1/status/IcingaApplication' ) {
                $content = '{"results":[{"status":{"icingaapplication":{"app":[]}}}]}'
            } elsif( _incallers(qr/query_parent_hosts/) ) {
                $content = '{"results":[{"attrs":{"vars":{"parents":["parent1","parent2"]}}}]}'
            }
        } # TODO else?

        my $r = $tx->res;
        $r->code(200);
        $r->body($content);
        return $tx;
    }

    sub calls { return shift->{calls} }

    sub _incallers {
        my $re = shift;
        my $f=1;
        my $caller;
        while(1) {
            $caller = (caller( $f++ ))[3] // return;
            return 1 if $caller =~ $re;
        };
        return;
    }

    sub _logcall {
        my $self = shift;
        my $sub = ( caller(1) )[3];
        push @{ $self->{calls} //= [] }, {
            method => $sub,
            args => clone(\@_),
        };
    }
}
