
use strict;
use warnings;

use Test::More tests => 11;
use HTTP::Request;

require 't/TestServer.pm';
my $s        = TestServer->new;
my $url_root = $s->started_ok("starting a test server");

use HTTP::Async;
my $q = HTTP::Async->new;

# Check that the timeout is at a sensible default.
is $q->timeout, 180, "\$q->timeout == 180";

{    # Send a request that should return quickly
    my $url = "$url_root?delay=0";
    my $req = HTTP::Request->new( 'GET', $url );
    ok $q->add($req), "Added request to the queue";
    $q->poke while !$q->to_return_count;

    my $res = $q->next_response;
    is $res->code, 200, "Not timed out (200)";
}

is $q->timeout(1), 1, "Set the timeout really low";

{    # Send a request that should timeout
    my $url = "$url_root?delay=3";
    my $req = HTTP::Request->new( 'GET', $url );
    ok $q->add($req), "Added request to the queue";
    $q->poke while !$q->to_return_count;

    my $res = $q->next_response;
    is $res->code, 504, "timed out (504)";
    ok $res->is_error, "is an error";
}

is $q->timeout(10), 10, "Lengthen the timeout";

{    # Send same request that should now be ok
    my $url = "$url_root?delay=3";
    my $req = HTTP::Request->new( 'GET', $url );
    ok $q->add($req), "Added request to the queue";
    $q->poke while !$q->to_return_count;

    my $res = $q->next_response;
    is $res->code, 200, "Not timed out (200)";
}
