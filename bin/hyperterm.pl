#!/usr/bin/perl
#
#---------------------------------------#
# Silly little program that attaches    #
# to the QN DAQ card (live or memorex)  #
# with a NOECHO & STREAM enabled on the #
# tty -- useful because this is the way #
# that M$ telnet & hyperterm start up   #
# by default, so it's good for testing  #
# what a user on a win(DOH!)$ machine   #
# will see when they use this DAQ class #
#---------------------------------------#
#
use strict;
use warnings;

use lib qw(lib);
use IO::Select;

use QN::Client;

use Getopt::Long;
Getopt::Long::Configure('bundling', 'ignore_case');

my $host = "localhost";
my $port = 8979;

GetOptions (
    "host|h=s" => \$host,
    "port|p=i" => \$port,
    '<>'           => sub {
	my ( $option ) = @_;
	print "Unknown option $option ignored\n";
    }
    );

my $continue = 1;

# Create the client
my $client = new Client( $host, $port );

STDIN->autoflush(1);
STDOUT->autoflush(1);
my $select = new IO::Select(\*STDIN);

# Put the terminal into "stream" mode
system "stty", '-icanon', 'eol', "\001";
system "stty", '-echo';

# Flush the welcome message
#print "Starting up\n";
my $read = $client->read(1);
print $read if $read;

while ( $continue ) {

    my $command = "";
    while ( my $char = getc(STDIN) ) {
	if ( ord($char) == 13 || ord($char) == 10 ) {
	    print "\r";
	    last;
	} else {
	    print uc($char);
	    $command .= uc($char);
	}
    }

    if ( !$command ) {
	next;
    }

    if ( uc($command) =~ /CL/ || uc($command) =~ /CLOSE/ ) {
	$continue = 0;
	last;
    } elsif ( uc($command) =~ /DONE/ ) {
	$client->send($command);
	last;
    }

    $client->send($command);

    while ( my $reply = $client->read() ) {
	if ( $reply =~ /EOT/ ) {
	    last;
	}
	print "$reply" if $reply;

	# Check the terminal for user keypresses... and halt
	# the data stream (if any) should the user be typing
	if ( $select->can_read(0.001) ) {
	    $command = "";
	    while ( my $char = getc(STDIN) ) {
		print "Got char $char ";
		if ( ord($char) == 13 || ord($char) == 10 ) {
		    print "\r";
		    last;
		} else {
		    print uc($char);
		    $command .= $char;
		}
	    }
	    $client->send($command);
	}
    }
}

# Return the terminal to normal 
system 'stty', 'icanon', 'eol', '^@'; # ASCII NUL
system "stty", 'echo';

# And shut down the client
$client->send(undef);
$client->close();

exit 0;
