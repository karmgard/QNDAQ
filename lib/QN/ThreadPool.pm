package ThreadPool;

use strict;
use warnings;

use threads;
use threads::shared;

use Time::HiRes qw(usleep);

use QN::ThreadQueue;

our $active : shared = 0;

sub new {
    my ( $class, $min, $max, $thread, $verbose ) = @_;

    if ( !$min ) {
	$min = 5;
    }

    if ( !$max ) {
	$max = 3*$min+1;
    }

    my $self = {
    _threadFunc    => $thread,
    _min           => $min,
    _max           => $max,
    _verbose       => $verbose,
    _queue         => new ThreadQueue(),
    _pool          => undef
    };
    bless( $self, $class );

    for ( my $i=0; $i<$min; $i++ ) {
	push( @{$self->{_pool}}, threads->new($thread, $self->{_queue}));
    }

#    use Data::Dumper;
#    print Dumper(@{$self->{_pool}}[0]->tid()) . "\n";
#    exit 0;

    return $self;
}

sub close {
    my ( $self ) = @_;

    for ( my $i=scalar @{$self->{_pool}}; $i>=0; $i-- ) {
	$self->{_queue}->enqueue(undef);
    }

    usleep(25000);

    foreach my $thread (@{$self->{_pool}}) {
	$thread->kill('STOP');
	$thread->detach();
    }

    return undef;
}

sub poolSize {
    my ( $self ) = @_;
    return eval( scalar(@{$self->{_pool}}) + 1);
}

sub active {
    my ( $self ) = @_;
    return $active;
}

sub checkPoolSize {
    my ( $self ) = @_;

    my $size   = $self->poolSize();

    # If we're approaching saturation...
    if ( $active > eval(0.8*$size) ) {
	# Double the size of the pool up to the max
	$self->expand($size);

    # If we're way over what we need on the other hand....
    } elsif ( $active < eval(0.2*$size) ) {
	# Cut the pool size in half
	$self->shrink(eval($size/2));
    }

    return;
}

sub enqueue {
    my ( $self, $item ) = @_;
    # We have a new task
    $self->{_queue}->enqueue($item);

    return;
}

sub dequeue {
    my ( $self ) = @_;
    return $self->{_queue}->dequeue() if $self->{_queue} || undef;
}

sub pending {
    my ( $self ) = @_;
    return $self->{_queue}->pending() if $self->{_queue} || undef;
}

sub peek {
    my ( $self, $item ) = @_;
    return $self->{_queue}->peek($item) if $self->{_queue} || undef;
}

sub sort {
    my ( $self ) = @_;
    $self->{_queue}->sort() if $self->{_queue};
    return;
}

sub expand {
    my ( $self, $workerThreads ) = @_;

    if ( !$workerThreads ) {
	$workerThreads = 5;
    }

    my $maximum = $self->{_max};
    my $maxExpand = $maximum - scalar(@{$self->{_pool}}) - 1;

    if ( $maxExpand <= 0 ) {
	return;
    }

    if ( $workerThreads > $maxExpand ) {
	$workerThreads = $maxExpand;
    }

    if ( $self->{_verbose} ) {
	print "Expanding thread pool by $workerThreads ... ";
    }

    for ( my $i=0; $i<$workerThreads; $i++ ) {
	push( @{$self->{_pool}},
	      threads->new($self->{_threadFunc}, $self->{_queue}) )
    }

    if ( $self->{_verbose} ) {
	print "pool size now " . eval(scalar(@{$self->{_pool}}) + 1) . "\n";
    }

    return scalar(@{$self->{_pool}});
}

sub shrink {
    my ( $self, $workerThreads ) = @_;

    if ( !$workerThreads ) {
	$workerThreads = $self->{_min}/2;
    }

    my $minimum = $self->{_min};
    my $maxdelete = scalar(@{$self->{_pool}}) - $minimum + 1;

    if ( $maxdelete <= 0 ) {
	return;
    }

    if ( $workerThreads > $maxdelete ) {
	$workerThreads = $maxdelete;
    }

    if ( $self->{_verbose} ) {
	print "Shrinking thread pool by $workerThreads of " . 
	    eval(scalar(@{$self->{_pool}}) + 1) . "...";
    }

    for ( my $i=0; $i<$workerThreads; $i++ ) {
	$self->{_queue}->enqueue(undef);
    }
    usleep(10000);

    my @joinable = threads->list( my $is_joinable=0 );
    foreach my $join (@joinable) {
	my $id = $join->join();
	for ( my $i=0; $i<scalar(@{$self->{_pool}}); $i++ ) {
	    if ( $id == $self->{_pool}->[$i]->tid() ) {
		splice( @{$self->{_pool}}, $i, 1 );
	    }
	}
    }

    if ( $self->{_verbose} ) {
	print "Pool size now " . eval(scalar(@{$self->{_pool}})+1) . "\n";
    }

    return scalar(@{$self->{_pool}});
}

return 1;
