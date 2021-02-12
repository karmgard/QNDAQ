$Tk::MacProgressBar::VERSION = '1.0';

package Tk::MacProgressBar;

use base qw/Tk::Frame/;
use vars qw/$BASE $CAP $H $OTLW $W/;
use strict;

Construct Tk::Widget 'MacProgressBar';

$OTLW = 1 + 1;			# inner black and outter grey outline width
$BASE = 2;			# left base segment width
$CAP = 6;			# right cap width
$H = 10;			# progress bar height

sub Populate {

    # Create an instance of a MacProgressBar.  Instance variable are:
    #
    # {photow} = Photo image width, including base and end cap.

    my($self, $args) = @_;

    $self->SUPER::Populate($args);

    my $w = $args->{-width};
    $w ||= 100;
    $self->{photow} = $w = $w + $BASE + $CAP;
    my $h = 2 * $OTLW + $H;

    # The MacProgressbar Label and its surrounding top/left/right/bottom
    # Frames, plus an empty Photo for the Label's image.  Pack things nicely.

    my $tf = $self->Frame;
    my $lf = $self->Frame;
    my $lb = $self->Label;
    my $rf = $self->Frame;
    my $bf = $self->Frame;

    my $i = $lb->Photo(-width => $w, -height => $h);
    $lb->configure(-image => $i);

    $tf->pack(qw/-fill both -expand 1 -side top/);
    $bf->pack(qw/-fill both -expand 1 -side bottom/);
    $lf->pack(qw/-fill both -expand 1 -side left/);
    $lb->pack(qw/-fill both -expand 1 -side left -ipadx 6/);
    $rf->pack(qw/-fill both -expand 1 -side left/);

    # Draw the outer and inner image outlines.

    my $left_top_outter = '#adadad';
    my $right_bottom_outter = '#ffffff';

    $i->put($left_top_outter,     -to =>      0,      0, $w - 0,      1);
    $i->put('#000000',            -to =>      1,      1, $w - 1,      2);
    $i->put($left_top_outter,     -to =>      0,      0,      1, $h - 0);
    $i->put('#000000',            -to =>      1,      1,      2, $h - 1);

    $i->put($right_bottom_outter, -to =>      0, $h - 0, $w - 0, $h - 1);
    $i->put('#000000',            -to =>      1, $h - 1, $w - 1, $h - 2);
    $i->put($right_bottom_outter, -to => $w - 1, $h - 0, $w - 0,      1);
    $i->put('#000000',            -to => $w - 2, $h - 1, $w - 1,      1);

    # Advertise important user subwidgets. All mega-widget configuration
    # requests default to the Label. Define a handler that will delete the
    # MacProgressBar image upon widget destruction.

    $self->Advertise('tframe' => $tf);
    $self->Advertise('lframe' => $lf);
    $self->Advertise('label'  => $lb);
    $self->Advertise('rframe' => $rf);
    $self->Advertise('bframe' => $bf);

    $self->ConfigSpecs(DEFAULT => [$lb]);
    $self->OnDestroy([$self => 'free_photo']);

} # end Populate

sub free_photo {
    return;
    # Free the MacProgressBar image.
    $_[0]->Subwidget('label')->cget(-image)->delete;

} # end free_photo

sub set {

    # This is the meat of the MacProgressBar mega-widget, where we
    # first "blank" the image by filling it with the background color,
    # then paint the base, a progress bar of the desired width, and
    # the end cap.

    my($self, $percent) = @_;

#    warn "Tk::MacProgressBar: percent ($percent) > 100." if $percent > 100;
    $percent = ($percent <= 100) ? $percent : 100;

    my $l = $self->Subwidget('label');
    return unless defined $l;	# Destroy in progress
    my $i = $l->cget(-image);
    my $w = ( $self->{photow} - ( $BASE + $CAP ) ) / 100 * $percent;
    if ($w >= $self->{photow} - $CAP) {
        $w = $self->{photow} - $CAP - 1;
    }
    my $h = 2 * $OTLW + $H;

    # Clear image with background color.

    $i->put('#bdbdbd',
        -to => $OTLW + 0, $OTLW + 0, $self->{photow} - $OTLW, $h - $OTLW);

    # Draw the two-pixel-wide progress bar base.
  
    $i->put('#6363ce', -to => $OTLW + 0, $OTLW + 0, $OTLW + 1, $h - $OTLW);
    $i->put([
        '#6363ce', '#9c9cff', '#ceceff',
        '#efefef', '#efefef', '#efefef',
        '#ceceff', '#9c9cff', '#6363ce', '#31319c',
    ], -to => $OTLW + 1, $OTLW + 0, $OTLW + 2, $h - $OTLW);

    # Draw an appropriately wide progress bar.

    $i->put([
        '#30319d', '#6563cd', '#9c9cff',
        '#ceceff', '#f0f0f0', '#ceceff',
        '#9c9cff', '#6563cd', '#30319d', '#020152',
    ], -to => $OTLW + $BASE, $OTLW, $OTLW + $BASE + $w, $h - $OTLW);

    # Draw the six-pixel-wide progress bar end cap.

    my $x = 0;
    foreach my $pixels (
          ['#31319c', '#6363ce', '#9c9cff', '#ceceff', '#ceceff',
           '#ceceff', '#9c9cff', '#6363ce', '#31319c', '#000082'],
          ['#31319c', '#6363ce', '#31319c', '#31319c', '#31319c',
           '#31319c', '#31319c', '#31319c', '#31319c', '#000052'],
          ['#31319c', '#000052', '#000052', '#000052', '#000052',
           '#000052', '#000052', '#000052', '#000052', '#000052'],
          ['#000000', '#000000', '#000000', '#000000', '#000000',
           '#000000', '#000000', '#000000', '#000000', '#000000'],
          ['#525252', '#525252', '#525252', '#525252', '#525252',
           '#525252', '#525252', '#525252', '#525252', '#525252'],
          ['#8c8c8c', '#8c8c8c', '#8c8c8c', '#8c8c8c', '#8c8c8c',
           '#8c8c8c', '#8c8c8c', '#8c8c8c', '#8c8c8c', '#8c8c8c'],
        ) {
	$i->put($pixels,    
		-to => $OTLW + $BASE + $x + $w,          $OTLW,
		       $OTLW + $BASE + $x + $w + 1, $h - $OTLW);
	$x++;
    }

    $self->update;
  
} # end set

1;

__END__

=head1 NAME

Tk::MacProgressBar - a blue, 3-D Macintosh progress bar.

=head1 SYNOPSIS

S<    >I<$pb> = I<$parent>-E<gt>B<MacProgressBar>(I<-option> =E<gt> I<value>);

=head1 DESCRIPTION

This widget provides a dynamic image that looks just like a Mac OS 9
progress bar.  Packed around it are four Frames, north, south, east and
west, within which you can stuff additional widgets. For example, see
how MacCopy uses several Labels and a CollapsableFrame widget to create
a reasonable facsimile of a Macintosh copy dialog.

The following option/value pairs are supported:

=over 4

=item B<-width>

The maximun width of the MacProgressbar.

=back

=head1 METHODS

=over 4

=item B<set($percent)>

Sets the width of the progress bar, as a percentage of -width.

=back

=head1 ADVERTISED WIDGETS

Component subwidgets can be accessed via the B<Subwidget> method.
Valid subwidget names are listed below.

=over 4

=item Name:  label, Class:  Label

  Widget reference of the Label containing the MacProgressBar
  Photo image.

=item Name:  tframe, Class:  Frame

  Widget reference of the Frame north the MacProgressBar.

=item Name:  bframe, Class:  Frame

  Widget reference of the Frame south the MacProgressBar.

=item Name:  lframe, Class:  Frame

  Widget reference of the Frame west the MacProgressBar.

=item Name:  rframe, Class:  Frame

  Widget reference of the Frame east the MacProgressBar.

=back

=head1 EXAMPLE

 use Tk;
 use Tk::MacProgressBar;
 use strict;

 my $mw = MainWindow->new;
 my $pb = $mw->MacProgressBar(-width => 150, -bg => 'cyan')->pack;

 while (1) {
     my $w = rand(100);
     $pb->set($w);
     $mw->update;
     $mw->after(250);
 }

=head1 AUTHOR and COPYRIGHT

Stephen.O.Lidie@Lehigh.EDU

Copyright (C) 2000 - 2001, Stephen O.Lidie.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=head1 KEYWORDS

MacProgressBar

=cut
