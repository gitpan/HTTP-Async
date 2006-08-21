
use strict;
use warnings;

use Test::More tests => 23;
use HTTP::Request;
use Time::HiRes 'time';

require 't/TestServer.pm';
my $s        = TestServer->new;
my $url_root = $s->started_ok("starting a test server");

use HTTP::Async;
my $q = HTTP::Async->new;

# Send off a long request - check that next_response returns at once
# but that wait_for_next_response returns only when the response has arrived.

# Check that the poll interval is at a sensible default.
is $q->poll_interval, 0.05, "\$q->poll_interval == 0.05";

# Check that the poll interval is changeable.
is $q->poll_interval(0.1), 0.1, "set poll_interval to 0.1";
is $q->poll_interval, 0.1, "\$q->poll_interval == 0.1";

{
    my $url = "$url_root?delay=3";
    my $req = HTTP::Request->new( 'GET', $url );
    ok $q->add($req), "Added request to the queue";

    # Get the time since the request was made.
    my $start_time = time;

    # Does next_response return immediately
    ok !$q->next_response, "next_response returns at once";
    ok time - $start_time < 0.1, "Returned quickly (less than 0.1 secs)";

    ok !$q->wait_for_next_response(0),
      "wait_for_next_response(0) returns at once";
    ok time - $start_time < 0.1, "Returned quickly (less than 0.1 secs)";

    ok !$q->wait_for_next_response(1),
      "wait_for_next_response(1) returns after 1 sec without a response";
    ok time - $start_time > 1 && time - $start_time < 1.1,
      "Returned after 1 sec delay";

    my $response = $q->wait_for_next_response(3);
    ok $response, "wait_for_next_response got the response";
    ok time - $start_time > 3, "Returned after 3 sec delay";

    is $response->code, 200, "timed out (200)";
    ok $response->is_success, "is a success";
}

{
    my $url = "$url_root?delay=1";
    my $req = HTTP::Request->new( 'GET', $url );
    ok $q->add($req), "Added request to the queue";

    # Get the time since the request was made.
    my $start_time = time;

    my $response = $q->wait_for_next_response;
    ok $response, "wait_for_next_response got the response";
    ok time - $start_time > 1, "Returned after 1 sec delay";
    ok time - $start_time < 2, "Returned before 2 sec delay";

    is $response->code, 200, "timed out (200)";
    ok $response->is_success, "is a success";
}

{

    # Check that wait_for_next_response does not hang if there is nothing
    # to wait for.

    # Get the time since the request was made.
    my $start_time = time;

    ok !$q->wait_for_next_response, "Did not get a response";

    ok time - $start_time < 1, "Returned in less than 1 sec";
}
