package Device::BusPirate::Mode::SPI;

use strict;
use warnings;
use base qw( Device::BusPirate::Mode );

our $VERSION = '0.01';

use Carp;

use constant MODE => "SPI";

use constant {
   CONF_CS     => 0x01,
   CONF_AUX    => 0x02,
   CONF_PULLUP => 0x04,
   CONF_POWER  => 0x08,
};

=head1 NAME

C<Device::BusPirate::Mode::SPI> - use C<Device::BusPirate> in SPI mode

=head1 DESCRIPTION

This object is returned by a L<Device::BusPirate> instance when switching it
into C<SPI> mode. It provides methods to configure the hardware, and interact
with an SPI-attached chip.

=cut

my $EXPECT_ACK = sub {
   my ( $buf ) = @_;
   $buf eq "\x01" or return Future->fail( "Expected ACK response" );
   return Future->done;
};

=head1 METHODS

The following methods documented with a trailing call to C<< ->get >> return
L<Future> instances.

=cut

sub start
{
   my $self = shift;

   # Bus Pirate defaults
   $self->{pin_3v3} = 0;
   $self->{cpha}    = 0;
   $self->{cpol}    = 1;
   $self->{sample}  = 0;

   $self->{cs_high} = 0;

   $self->{cs}     = 0;
   $self->{power}  = 0;
   $self->{pullup} = 0;
   $self->{aux}    = 0;

   $self->_start_mode_and_await( "\x01", "SPI" )->then( sub {
      $self->pirate->read( 1 )->then( sub {
         ( $self->{version} ) = @_;
         return Future->done( $self );
      })
   });
}

=head2 $mode->configure( %args )->get

Change configuration options. The following options exist; all of which are
simple true/false booleans.

=over 4

=item pin_3v3

If enabled, output pins will be actively driven by 3.3V when high and GND when
low. When disabled (default) outputs will be of an open-drain type; hi-Z when
high but driven to GND when low.

=item cpha

=item cpol

The SPI Clock Phase (C<cpha>) and Clock Polarity (C<cpol>) settings.

=item sample

Whether to sample input in the middle of the clock phase or at the end.

=item cs_high

Whether "active" Chip Select should be at high level. Defaults false to be
active-low. This only affects the C<writeread_cs> method; not the
C<chip_select> method.

=back

=cut

sub configure
{
   my $self = shift;
   my %args = @_;

   defined $args{$_} and $self->{$_} = !!$args{$_}
      for (qw( pin_3v3 cpha cpol sample cs_high ));

   $self->pirate->write( chr( 0x80 |
      ( $self->{pin_3v3} ? 0x08 : 0 ) |
      ( $self->{cpha}    ? 0x04 : 0 ) |
      ( $self->{cpol}    ? 0x02 : 0 ) |
      ( $self->{sample}  ? 0x01 : 0 ) )
   );
   $self->pirate->read( 1 )->then( $EXPECT_ACK );
}

=head2 $mode->chip_select( $cs )->get

Set the C<CS> output pin level. A false value will pull it to ground. A true
value will either pull it up to 3.3V or will leave it in a hi-Z state,
depending on the setting of the C<pin_3v3> configuration.

=cut

sub chip_select
{
   my $self = shift;
   $self->{cs} = !!shift;

   $self->pirate->write( $self->{cs} ? "\x03" : "\x02" );
   $self->pirate->read( 1 )->then( $EXPECT_ACK );
}

=head2 $mode->power( $power )->get

Enable or disable the C<VREG> 5V and 3.3V power outputs.

=cut

sub power
{
   my $self = shift;
   $self->{power} = !!shift;
   $self->_update_peripherals;
}

=head2 $mode->pullup( $pullup )->get

Enable or disable the IO pin pullup resistors from C<Vpu>. These are connected
to the C<MISO>, C<SCK>, C<MOSI> and C<CS> pins.

=cut

sub pullup
{
   my $self = shift;
   $self->{pullup} = !!shift;
   $self->_update_peripherals;
}

=head2 $mode->aux( $aux )->get

Set the C<AUX> output pin level.

=cut

sub aux
{
   my $self = shift;
   $self->{aux} = !!shift;
   $self->_update_peripherals;
}

sub _update_peripherals
{
   my $self = shift;

   $self->pirate->write( chr( 0x40 |
      ( $self->{power}  ? CONF_POWER  : 0 ) |
      ( $self->{pullup} ? CONF_PULLUP : 0 ) |
      ( $self->{aux}    ? CONF_AUX    : 0 ) |
      ( $self->{cs}     ? CONF_CS     : 0 ) )
   );
   $self->pirate->read( 1 )->then( $EXPECT_ACK );
}

=head2 $miso_bytes = $mode->writeread( $mosi_bytes )->get

Performs an actual SPI data transfer. Writes bytes of data from C<$mosi_bytes>
out of the C<MOSI> pin, while capturing bytes of input from the C<MISO> pin,
which will be returned as C<$miso_bytes> when the Future completes. This
method does I<not> toggle the C<CS> pin, so is safe to call multiple times to
effect a larger transaction.

=cut

sub writeread
{
   my $self = shift;
   my ( $bytes ) = @_;

   length $bytes <= 16 or croak "Can only writeread up to 16 bytes at once";

   my $len_1 = length( $bytes ) - 1;

   $self->pirate->write( chr( 0x10 | $len_1 ) );
   $self->pirate->write( $bytes );

   $self->pirate->read( 1 )->then( sub {
      my ( $buf ) = @_;
      $buf eq "\x01" or return Future->fail( "Expected ACK response" );

      $self->pirate->read( length $bytes );
   });
}

=head2 $miso_bytes = $mode->writeread_cs( $mosi_bytes )->get

A convenience wrapper around C<writeread> which toggles the C<CS> pin before
and afterwards. It uses the C<cs_high> configuration setting to determine the
active sense of the chip select pin.

=cut

sub writeread_cs
{
   my $self = shift;
   my ( $bytes ) = @_;

   $self->chip_select( $self->{cs_high} )->then( sub {
      $self->writeread( $bytes )
   })->then( sub {
      my ( $buf ) = @_;
      $self->chip_select( !$self->{cs_high} )->then_done( $buf );
   });
}

=head1 TODO

=over 4

=item *

SPI speed in C<configure>.

=item *

Move peripheral methods into L<Device::BusPirate::Mode> so other modes can
share it.

=back

=cut

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
