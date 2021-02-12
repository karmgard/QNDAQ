#!/usr/bin/perl

use strict;
use warnings;

use lib qw(lib);
use QN::cardWeb;
use QN::options;

my $verbose    = 0;
my $daemon     = 0;
my $password   = undef;
my $crdport    = 8979;
my $webport    = 8008;
my $chatport   = 8888;
my @whitelist;
my @blacklist;

my $workers    = 4;
my $maxClients = 25;

# Process the config file & command line options
# Routine is located in lib/QN/options.pm for clarity
# It returns a reference to a hash of options
my $optHash = procOptions::procOptions(my $doStartDump = 0);

$crdport    = $optHash->{port};
$webport    = $optHash->{webport};
$chatport   = $optHash->{chatport};
$password   = $optHash->{password};
$verbose    = $optHash->{verbose};
$daemon     = $optHash->{daemon};

my %listHash = (
    'whitelist' => \@{$optHash->{whitelist}},
    'blacklist' => \@{$optHash->{blacklist}}
);

if ( $daemon ) {

    if ( $^O =~ /MSWin32/i ) {   # If this is a winders machine....
	                         # WHAT THE @#_%)($@# WERE YOU THINKING!?!
	my $pid = system(1, $optHash->{command}, @{$optHash->{options}});
	exit 0;
    } else {                     # Run this like a sensible system
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

my $webServer = cardWeb->start($verbose,$password,$webport,$chatport,
			       $crdport,$workers, $maxClients, %listHash) ||
    die "Unable to start server: $!\n";

my $continue = 1;
$SIG{'TERM'} = $SIG{'STOP'} = $SIG{'INT'} = sub { $continue = 0; return; };
while ( $continue ) {
    sleep 1;
}

$webServer->stop();
exit 0;
