use strict;
use warnings;

use Test::More tests => 3;
use HTTP::Request;

require 't/TestServer.pm';
my $s        = TestServer->new();
my $url_root = $s->started_ok("starting a test server");

use HTTP::Async;
my $q = HTTP::Async->new;

my $req = HTTP::Request->new( 'GET', "$url_root?delay=0" );
$req->header( 'Cookie', 'foo=bar' );

ok $q->add($req), "Added request to the queue";
$q->poke while !$q->to_return_count;

my $res = $q->next_response;
is $res->code, 200, "Got a response";
