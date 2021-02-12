package ThreadQueue;

use strict;
use warnings;

use threads;
use threads::shared;

sub new {
    my ( $class ) = shift(@_);
    my @queue :shared;
    return bless(\@queue, $class);
}

sub cleanup {
    my ($queue) = shift(@_);
    lock($queue);
    while ( shift(@$queue) ) {;}
    undef $queue;
    return undef;
}

sub enqueue {
    my $queue = shift(@_);
    lock(@$queue);
    push( @$queue, shift(@_) ) && cond_signal(@$queue);
    return;
}

sub pending {
    my $queue = shift(@_);
    lock(@$queue);
    return eval( scalar(@$queue) );
}

sub test {
    my $queue   = shift(@_);
    my $timeout = shift(@_);

    # Timeout: < undef || < 0 => blocking
    #        : = 0 => non-blocking
    #        : > 0 => timeout after $timeout seconds

    if ( !defined($timeout) || $timeout < 0 ) {
	lock(@$queue);

	# Wait until something is there
	cond_wait(@$queue)   until ( scalar(@$queue) >= 1 );
	cond_signal(@$queue) if    ( scalar(@$queue) >  1 );
	return shift(@$queue);

    } elsif ( $timeout == 0 ) {  # Non-blocking mode
	return shift(@$queue) if scalar(@$queue) > -1;

    } else {

	my $timer = 0;
	while ( scalar(@$queue) < 1 ) {
	    sleep(1);
	    $timer++;
	    if ( $timer > $timeout ) {
		last;
	    }
	}
	if ( scalar(@$queue) >= 1 ) {
	    lock(@$queue);
	    cond_signal(@$queue);
	    return shift(@$queue);
	} else {
	    return undef;
	}
    }

    return undef;
}

sub dequeue {
    my $queue = shift(@_);
    my $noblock = shift(@_);

    lock(@$queue);

    if ( !$noblock ) {      # Wait until something is there
	cond_wait(@$queue)   until ( scalar(@$queue) >= 1 );
	cond_signal(@$queue) if    ( scalar(@$queue) >  1 );
	return shift(@$queue);
    } else {                # Immediate return regardless
	return shift(@$queue) if scalar(@$queue) > -1;
    }
    return undef;
}

sub peek {
    my $queue = shift(@_);
    lock(@$queue);

    my $index = @_ ? shift(@_) : 0;
    my $count = scalar(@$queue);

    if ( $index <= $count ) {
	return $$queue[$index];
    } else {
	return;
    }
}

sub insert {
    my $queue = shift(@_);
    lock(@$queue);

    my $index = @_ ? shift(@_) : 0;
    return if (! @_);   # Nothing to insert

    my @tmp;
    while (@$queue > $index) {
        unshift(@tmp, pop(@$queue))
    }

    # Add new items to the queue
    push(@$queue, shift(@_) );

    # Add previous items back onto the queue
    push(@$queue, @tmp);

    cond_signal(@$queue);

    return;
}

# Sort the queue by 1) priority and 2) first in
sub sort {
    my $queue = shift(@_);
    lock(@$queue);
    @$queue = sort { 
	my ($pa) = split(/:/, $a);
	my ($pb) = split(/:/, $b);
	return ( $pa <=> $pb );
    } @$queue;

    return;
}



return 1;
