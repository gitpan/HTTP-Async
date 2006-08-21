use strict;
use warnings;

# Provide a simple server that can be used to test the various bits.
package TestServer;
use base qw/Test::HTTP::Server::Simple HTTP::Server::Simple::CGI/;

use Data::Dumper;

sub handle_request {
    my ( $self, $cgi ) = @_;
    my $params = $cgi->Vars;

    # Do the right thing depending on what is asked of us.
    if ( exists $params->{redirect} ) {
        my $num = $params->{redirect} || 0;
        $num--;

        if ( $num > 0 ) {
            print $cgi->redirect( -uri => "?redirect=$num", -nph => 1, );
            print "You are being redirected...";
        }
        else {
            print $cgi->header( -nph => 1 );
            print "No longer redirecting";
        }
    }

    elsif ( exists $params->{delay} ) {
        sleep $params->{delay};
        print $cgi->header( -nph => 1 );
        print "Delayed for '$params->{delay}'.";
    }

    elsif ( exists $params->{bad_header} ) {
        my $headers = $cgi->header( -nph => 1, );

        # trim trailing whitspace to single newline.
        $headers =~ s{ \s* \z }{\n}xms;

        # Add a bad header:
        $headers .= "Bad header: BANG!\n";

        print $headers . "\n\n";
        print "Produced some bad headers.";
    }

    else {
        warn "DON'T KNOW WHAT TO DO: " . Dumper $params;
    }
}

1;
