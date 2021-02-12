#!/usr/bin/perl

use strict;
use warnings;

use lib qw(lib);
use QN::options;
use QN::daqChat;

my $verbose : shared = 0;
my $workers    = 4;
my $maxClients = 25;
my $chatport   = 8888;
my $daemon     = 0;
my $cril       = 0;
my $password;

# Process the config file & command line options
# Routine is located in lib/QN/options.pm for clarity
# It returns a reference to a hash of options
my $optRef = procOptions::procOptions(my $doStartDump = 0);

$chatport   = $optRef->{chatport};
$workers    = $optRef->{workers};
$maxClients = $optRef->{maxclients};
$verbose    = $optRef->{verbose};
$password   = $optRef->{password};
$daemon     = $optRef->{daemon};
$cril       = $optRef->{cril};

my %listHash = (
    'whitelist' => \@{$optRef->{whitelist}},
    'blacklist' => \@{$optRef->{blacklist}}
);

if ( $daemon ) {

    if ( $^O =~ /MSWin32/i ) {   # If this is a winders machine....
	                         # WHAT THE @#_%)($@# WERE YOU THINKING!?!
	my $pid = system(1, $optRef->{command}, @{$optRef->{options}});
	exit 0;
    } else {                     # Run this same thing on a sensible system
	my $pid = fork();
	if ( !defined($pid) ) {
	    die "Screaming!\n";
	} elsif ( $pid ) {
	    exit 0;
	}
    }

    # If we're background... don't make any noise
    $verbose = 0;
}

my $chatServer = daqChat->start($verbose,$password,$chatport,
				$workers, $maxClients, $cril, %listHash) ||
    die "Unable to start server: $!\n";

my $continue = 1;
my $shutdown = 0;
$SIG{'TERM'} = $SIG{'STOP'} = $SIG{'INT'} = sub { 
    $shutdown = 1;
    return; 
};
while ( !$shutdown && $continue ) {
    $continue = $chatServer->running();
}
if ( $chatServer ) {
    $chatServer->stop();
}

exit 0;
