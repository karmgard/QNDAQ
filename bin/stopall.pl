#!/usr/bin/perl

use strict;
use warnings;

use lib qw(lib);
use IO::Socket;
use QN::options;

my $CRLF = "\015\012";  # \r\n
my $CR   = "\015";      # \r
my $LF   = "\012";      # \n

# Process the config file & command line options
# Routine is located in lib/QN/options.pm for clarity
# It returns a reference to a hash of options
my $optRef = procOptions::procOptions( my $doStartupDump = 0 );


my @ports = ( $optRef->{port}, $optRef->{webport}, $optRef->{chatport}, 843 );

my $host = 'localhost';
my $proto = getprotobyname('tcp');
my $socket;

foreach my $port (@ports) {

    $socket = new IO::Socket::INET (
	PeerAddr  => $host,
	Proto     => $proto,
	PeerPort  => $port,
	ReuseAddr => 1
    );

    if ( !$socket ) {
	warn "Can't connect to $port: $!\n" unless $socket;
	next;
    }

    $socket->autoflush(1);

    if ( $port == $optRef->{port} || $port == $optRef->{chatport} ) {
	my $read = <$socket>;
	print $socket "done$CRLF";
	$read = <$socket>;
    } elsif ( $port == $optRef->{webport} ) {
	print $socket "GET alldone$CRLF";
    } elsif ( $port == 843 ) {
	$/ = "\0";
	print $socket "done\0";
    } else {
	print "What the?\n";
    }
    $socket->close();
}

exit 0;
