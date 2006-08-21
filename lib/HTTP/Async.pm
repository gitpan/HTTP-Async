use strict;
use warnings;

package HTTP::Async;

our $VERSION = '0.01';

use Carp;
use Data::Dumper;
use HTTP::Response;
use IO::Select;
use Net::HTTP::NB;
use Net::HTTP;
use URI;
use Time::HiRes qw( time sleep );

# TODO: add 'info' sub that can be linked to SIGINFO to provide a
# summary of what is going on eg "print $async->info( 'terse' )".

=head1 NAME

HTTP::Async - process multiple HTTP requests in parallel without blocking.

=head1 SYNOPSIS

Create an object and add some requests to it:

    use HTTP::Async;
    my $async = HTTP::Async->new;
    
    # create some requests and add them to the queue.
    $async->add( HTTP::Request->new( GET => 'http://www.perl.org/'         ) );
    $async->add( HTTP::Request->new( GET => 'http://www.ecclestoad.co.uk/' ) );

and then EITHER process the responses as they come back:

    while ( my $response = $async->wait_for_next_response ) {
        # Do some processing with $response
    }
    
OR do something else if there is no response ready:
    
    while ( $async->not_empty ) {
        if ( my $response = $async->next_response ) {
            # deal with $response
        } else {
            # do something else
        {
    }

OR just use the async object to fetch stuff in the background and deal with
the responses at the end.

    # Do some long code...
    for ( 1 .. 100 ) {
      some_function();
      $async->poke;            # lets it check for incoming data.
    }

    while ( my $response = $async->wait_for_next_response ) {
        # Do some processing with $response
    }    

=head1 DESCRIPTION

Although using the conventional C<LWP::UserAgent> is fast and easy it does
have some drawbacks - the code execution blocks until the request has been
completed and it is only possible to process one request at a time.
C<HTTP::Async> attempts to address these limitations.

It gives you a 'Async' object that you can add requests to, and then get the
requests off as they finish. The actual sending and receiving of the requests
is abstracted. As soon as you add a request it is transmitted, if there are
too many requests in progress at the moment they are queued. There is no
concept of starting or stopping - it runs continuously.

Whilst it is waiting to receive data it returns control to the code that
called it meaning that you can carry out processing whilst fetching data from
the network. All without forking or threading - it is actually done using
C<select> lists.

=head1 Default settings:

There are a number of default settings that should be suitable for most uses.
However in some circumstances you might wish to change these.

         slots: 20
       timeout: 180 (seconds)
 max_redirects: 7
 poll_interval: 0.05 (seconds)

=head1 METHODS

=head2 new

    my $async = HTTP::Async->new;

Creates a new HTTP::Async object and sets it up.

=cut

sub new {
    my $class = shift;
    return bless {
        slots         => 20,
        max_redirects => 7,
        timeout       => 180,
        poll_interval => 0.05,

        to_send     => [],
        in_progress => {},
        to_return   => [],

        current_id   => 0,
        fileno_to_id => {},
    }, $class;
}

sub _next_id { return ++$_[0]->{current_id} }

=head2 slots, timeout, poll_interval and max_redirects

    $old_value = $async->slots;
    $new_value = $async->slots( $new_value );

Get/setters for the C<$async> objects config settings. Timeout is in seconds
(and is restarted for redirects).

Slots is the maximum number of parallel requests to make.

=cut

sub slots {
    my $self = shift;
    $$self{slots} = shift if @_;
    return $$self{slots};
}

sub timeout {
    my $self = shift;
    $$self{timeout} = shift if @_;
    return $$self{timeout};
}

sub poll_interval {
    my $self = shift;
    $$self{poll_interval} = shift if @_;
    return $$self{poll_interval};
}

sub max_redirects {
    my $self = shift;
    $$self{max_redirects} = shift if @_;
    return $$self{max_redirects};
}

=head2 add

    my @ids      = $async->add(@requests);
    my $first_id = $async->add(@requests);

Adds requests to the queues. Each request is given an unique integer id (for
this C<$async>) that can be used to track the requests if needed. If called in
list context an array of ids is returned, in scalar context the id of the
first request added is returned.

=cut

sub add {
    my $self    = shift;
    my @returns = ();

    foreach my $req (@_) {
        my $id = $self->_next_id;
        push @{ $$self{to_send} }, [ $req, $id ];
        push @returns, $id;
    }
    $self->poke;

    return wantarray ? @returns : $returns[0];
}

=head2 poke

    $async->poke;

At fairly frequent intervals some housekeeping needs to performed - such as
reading recieved data and starting new requests. Calling C<poke> lets the
object do this and then return quickly. Usually you will not need to use this
as most other methods do it for you.

You should use C<poke> if your code is spending time elsewhere (ie not using
the async object) to allow it to keep the data flowing over the network. If it
is not used then the buffers may fill up and completed responses will not be
replaced with new requests.

=cut

sub poke {
    my $self = shift;

    $self->_process_in_progress;
    $self->_process_to_send;

    return 1;
}

=head2 next_response

    my $response          = $async->next_response;
    my ( $response, $id ) = $async->next_response;

Returns the next response (as a L<HTTP::Response> object) that is waiting, or
returns undef if there is none. In list context it returns a (response, id)
pair, or an empty list if none. Does not wait for a response so returns very
quickly.

=cut

sub next_response {
    my $self = shift;
    return $self->_next_response(0);
}

=head2 wait_for_next_response

    my $response          = $async->wait_for_next_response( 3.5 );
    my ( $response, $id ) = $async->wait_for_next_response( 3.5 );

As C<next_response> but only returns if there is a next response or the time
in seconds passed in has elapsed. If no time is given then it blocks. Whilst
waiting it checks the queues every c<poll_interval> seconds. The times can be
fractional seconds.

=cut

sub wait_for_next_response {
    my $self     = shift;
    my $wait_for = shift;

    $wait_for = $self->timeout * $self->max_redirects
      if !defined $wait_for;

    return $self->_next_response($wait_for);
}

sub _next_response {
    my $self        = shift;
    my $wait_for    = shift || 0;
    my $end_time    = time + $wait_for;
    my $resp_and_id = undef;

    while ( !$self->empty ) {
        $resp_and_id = shift @{ $$self{to_return} };

        # last if we have a response or we have run out of time.
        last
          if $resp_and_id
          || time > $end_time;

        # sleep for the default sleep time.
        sleep $self->poll_interval;
    }

    # If there is no result return false.
    return unless $resp_and_id;

    # If we have a result return list or response depending on
    # context.
    return wantarray
      ? @$resp_and_id
      : $resp_and_id->[0];
}

=head2 to_send_count, to_return_count, in_progress_count and total_count

    my $pending = $async->to_send_count;

Returns the number of items in the various stages of processing.

=cut

sub to_send_count   { my $s = shift; $s->poke; scalar @{ $$s{to_send} }; }
sub to_return_count { my $s = shift; $s->poke; scalar @{ $$s{to_return} }; }

sub in_progress_count {
    my $s = shift;
    $s->poke;
    scalar keys %{ $$s{in_progress} };
}

sub total_count {
    my $self  = shift;
    my $count = 0;

    $self->poke;

    $count += scalar @{ $$self{to_send} };
    $count += scalar keys %{ $$self{in_progress} };
    $count += scalar @{ $$self{to_return} };

    return $count;
}

=head2 info

    print $async->info;

Prints a line describing what the current state is.

=cut

sub info {
    my $self = shift;
    $self->poke;

    return sprintf(
        "HTTP::Async status: %4u,%4u,%4u (send, progress, return)\n",
        scalar @{ $$self{to_send} },
        scalar keys %{ $$self{in_progress} },
        scalar @{ $$self{to_return} }
    );
}

=head2 empty, not_empty

    while ( $async->not_empty ) { ...; }
    while (1) { ...; last if $async->empty; }

Returns true or false depending on whether there are request or responses
still on the object.

=cut

sub empty {
    my $self = shift;
    return $self->total_count ? 0 : 1;
}

sub not_empty {
    my $self = shift;
    return !$self->empty;
}

=head2 DESTROY

The destroy method croaks if an object is destroyed but is not empty. This is
to help with debugging.

=cut

sub DESTROY {
    my $self = shift;
    carp "HTTP::Async object destroyed but still in use" if $self->total_count;
    return;
}

# Go through all the values on the select list and check to see if
# they have been fully recieved yet.

sub _process_in_progress {
    my $self = shift;

  HANDLE:
    foreach my $s ( $self->_io_select->can_read(0) ) {

        my $id = $self->{fileno_to_id}{ $s->fileno };
        die unless $id;
        my $hashref = $$self{in_progress}{$id};
        my $tmp     = $hashref->{tmp} ||= {};

        # Check that we have not timed-out.
        if ( time > $hashref->{timeout_at} ) {

            $self->_add_error_response_to_return(
                id       => $id,
                code     => 504,
                request  => $hashref->{request},
                previous => $hashref->{previous},
                content  => 'Timed out',
            );

            $self->_io_select->remove($s);
            delete $$self{fileno_to_id}{ $s->fileno };
            next HANDLE;
        }

        # If there is a code then read the body.
        if ( $$tmp{code} ) {
            my $buf;
            my $n = $s->read_entity_body( $buf, 1024 * 16 );
            $$tmp{is_complete} = 1 unless $n;
            $$tmp{content} .= $buf;

            # warn $buf;
        }

        # If no code try to read the headers.
        else {
            my ( $code, $message, %headers ) =
              $s->read_response_headers( laxed => 1, junk_out => [] );

            if ($code) {
                $$tmp{code}    = $code;
                $$tmp{message} = $message;
                my @headers_array = map { $_, $headers{$_} } keys %headers;
                $$tmp{headers} = \@headers_array;
            }
        }

        # If the message is complete then create a request and add it
        # to 'to_return';
        if ( $$tmp{is_complete} ) {
            delete $$self{fileno_to_id}{ $s->fileno };
            $self->_io_select->remove($s);

            # warn Dumper $$hashref{content};

            my $response =
              HTTP::Response->new(
                @$tmp{ 'code', 'message', 'headers', 'content' } );

            $response->request( $hashref->{request} );
            $response->previous( $hashref->{previous} ) if $hashref->{previous};

            # If it was a redirect and there are still redirects left
            # create a new request and unshift it onto the 'to_send'
            # array.
            if ( $response->is_redirect && $hashref->{redirects_left} > 0 ) {

                $hashref->{redirects_left}--;

                my $loc = $response->header('Location');
                my $uri = $response->request->uri;

                warn "Problem: " . Dumper( { loc => $loc, uri => $uri } )
                  unless $uri && ref $uri && $loc && !ref $loc;

                my $url = _make_url_absolute( url => $loc, ref => $uri );

                my $request = HTTP::Request->new( 'GET', $url );

                $self->_send_request( [ $request, $id ] );
                $hashref->{previous} = $response;
            }
            else {
                push @{ $$self{to_return} }, [ $response, $id ];
                delete $$self{in_progress}{$id};
            }

            delete $hashref->{tmp};
        }
    }

    return 1;
}

# Add all the items waiting to be sent to 'to_send' up to the 'slots'
# limit.

sub _process_to_send {
    my $self = shift;

    while ( scalar @{ $$self{to_send} }
        && $self->slots > scalar keys %{ $$self{in_progress} } )
    {
        $self->_send_request( shift @{ $$self{to_send} } );
    }

    return 1;
}

sub _send_request {
    my $self     = shift;
    my $r_and_id = shift;
    my ( $request, $id ) = @$r_and_id;

    my $uri = URI->new( $request->uri );

    my $s =
      eval { Net::HTTP::NB->new( Host => $uri->host, PeerPort => $uri->port ) };

    # We could not create a request - fake up a 503 response with
    # error as content.
    if ( !$s ) {

        $self->_add_error_response_to_return(
            id       => $id,
            code     => 503,
            request  => $request,
            previous => $$self{in_progress}{$id}{previous},
            content  => $@,
        );

        return 1;
    }

    my %headers = %{ $request->{_headers} };

    croak "Could not write request to $uri '$!'"
      unless $s->write_request( $request->method, $uri->as_string, %headers,
        $request->content );

    $self->_io_select->add($s);

    $$self{fileno_to_id}{ $s->fileno }       = $id;
    $$self{in_progress}{$id}{request}        = $request;
    $$self{in_progress}{$id}{timeout_at}     = time + $self->timeout;
    $$self{in_progress}{$id}{redirects_left} = $self->max_redirects
      unless exists $$self{in_progress}{$id}{redirects_left};

    return 1;
}

sub _io_select {
    my $self = shift;
    return $$self{io_select} ||= IO::Select->new();
}

sub _make_url_absolute {
    my %args = @_;

    my $in  = $args{url};
    my $ref = $args{ref};

    return $in if $in =~ m{ \A http:// }xms;

    my $ret = $ref->scheme . '://' . $ref->authority;
    return $ret . $in if $in =~ m{ \A / }xms;

    $ret .= $ref->path;
    return $ret . $in if $in =~ m{ \A [\?\#\;] }xms;

    $ret =~ s{ [^/]+ \z }{}xms;
    return $ret . $in;
}

sub _add_error_response_to_return {
    my $self = shift;
    my %args = @_;

    use HTTP::Status;

    my $response =
      HTTP::Response->new( $args{code}, status_message( $args{code} ),
        undef, $args{content} );

    $response->request( $args{request} );
    $response->previous( $args{previous} ) if $args{previous};

    push @{ $$self{to_return} }, [ $response, $args{id} ];
    delete $$self{in_progress}{ $args{id} };

    return $response;

}

=head1 GOTCHAS

The responses may not come back in the same order as the requests were made.

=head1 AUTHOR

Edmund von der Burg C<< <evdb@ecclestoad.co.uk> >>. 

L<http://www.ecclestoad.co.uk/>

=head1 LICENCE AND COPYRIGHT

Copyright (c) 2006, Edmund von der Burg C<< <evdb@ecclestoad.co.uk> >>.
All rights reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY FOR THE
SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN OTHERWISE
STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES PROVIDE THE
SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK AS TO THE QUALITY AND
PERFORMANCE OF THE SOFTWARE IS WITH YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE,
YOU ASSUME THE COST OF ALL NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING WILL ANY
COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR REDISTRIBUTE THE
SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE LIABLE TO YOU FOR DAMAGES,
INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL, OR CONSEQUENTIAL DAMAGES ARISING
OUT OF THE USE OR INABILITY TO USE THE SOFTWARE (INCLUDING BUT NOT LIMITED TO
LOSS OF DATA OR DATA BEING RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR
THIRD PARTIES OR A FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER
SOFTWARE), EVEN IF SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGES.

=cut

1;


1;
