package Device::BusPirate;

use strict;
use warnings;

our $VERSION = '0.01';

use Carp;

use Future::Utils qw( repeat );
use IO::Termios;

use Module::Pluggable
   search_path => "Device::BusPirate::Mode",
   require     => 1,
   sub_name    => "modes";
my %MODEMAP = map { $_->MODE => $_ } __PACKAGE__->modes;

=head1 NAME

C<Device::BusPirate> - interact with a F<Bus Pirate> device

=head1 DESCRIPTION

This module allows a program to interact with a F<Bus Pirate> hardware
electronics debugging device, attached over a USB-emulated serial port. In the
following description, the reader is assumed to be generally aware of the
device and its capabilities. For more information about the F<Bus Pirate> see:

=over 2

L<http://dangerousprototypes.com/docs/Bus_Pirate>

=back

This module and its various component modules are based on L<Future>, allowing
either synchronous or asynchronous communication with the attached hardware
device. For simple synchronous situations, the class may be used on its own,
and any method that returns a C<Future> instance should immediately call the
C<get> method on that instance to wait for and obtain the eventual result.

 my $mode = $pirate->enter_mode( "SPI" )->get;

=cut

=head1 CONSTRUCTOR

=cut

=head2 $pirate = Device::BusPirate->new( %args )

Returns a new C<Device::BusPirate> instance to communicate with the given
device. Takes the following named arguments:

=over 4

=item serial => STRING

Path to the serial port device node the Bus Pirate is attached to. If not
supplied, a default of F</dev/ttyUSB0> will be used.

=item baud => INT

Serial baud rate to communicate at. Normally it should not be necessary to
change this from its default of C<115200>.

=back

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $serial = $args{serial} || "/dev/ttyUSB0";
   my $baud   = $args{baud} || 115200;

   my $fh = IO::Termios->open( $serial, "$baud,8,n,1" )
      or croak "Cannot open serial port $serial - $!";

   $fh->setflag_icanon( 0 );
   $fh->setflag_echo( 0 );

   return bless {
      fh => $fh,
   }, $class;
}

=head1 METHODS

The following methods documented with a trailing call to C<< ->get >> return
L<Future> instances.

=cut

# For Modes
sub write
{
   my $self = shift;
   my ( $buf ) = @_;

   $self->{fh}->syswrite( $buf );
}

# For Modes
sub read
{
   my $self = shift;
   my ( $n ) = @_;

   push @{ $self->{read_f} }, [ $n, my $f = $self->_new_future ];

   return $f;
}

# For Modes
sub sleep
{
   my $self = shift;
   my ( $timeout ) = @_;

   croak "Cannot sleep twice" if $self->{sleep_f};
   $self->{sleep_f} = [ $timeout, my $f = $self->_new_future ];
   $f->on_cancel( sub { undef $self->{sleep_f} } );

   return $f;
}

=head2 $mode = $pirate->enter_mode( $modename )->get

Switches the attached device into the given mode, and returns an object to
represent that hardware mode to interact with. This will be an instance of a
class depending on the given mode name.

=over 4

=item C<SPI>

The SPI mode. Returns an instance of L<Device::BusPirate::Mode::SPI>.

=back

Once a mode object has been created, most of the interaction with the device
would be done using that mode object, as it will have methods relating to the
specifics of that hardware mode. See the classes listed above for more
information.

=cut

sub enter_mode
{
   my $self = shift;
   my ( $modename ) = @_;

   my $modeclass = $MODEMAP{$modename} or
      croak "Unrecognised mode '$modename'";

   $self->start->then( sub {
      ( $self->{mode} = $modeclass->new( $self ) )->start;
   });
}

=head2 $pirate->start->get

Starts binary IO mode on the F<Bus Pirate> device, enabling the module to
actually communicate with it. Normally it is not necessary to call this method
explicitly as it will be done by the setup code of the mode object.

=cut

sub start
{
   my $self = shift;

   Future->wait_any(
      $self->read( 5 )->then( sub {
         my ( $buf ) = @_;
         return Future->done( ( $self->{version} ) = $buf =~ m/^BBIO(\d)/ );
      }),
      repeat {
         $self->write( "\0" );
         $self->sleep( 0.05 );
      } foreach => [ 1 .. 20 ],
        otherwise => sub {
           Future->fail( "Timed out waiting for device to enter bitbang mode" )
        },
   );
}

=head2 $pirate->stop->get

Stops binary IO mode on the F<Bus Pirate> device and returns it to user
terminal mode. It may be polite to perform this at the end of a program to
return it to a mode that a user can interact with normally on a terminal.

=cut

sub stop
{
   my $self = shift;

   $self->write( "\0\x0f" );
}

# Future support
sub _new_future
{
   my $self = shift;
   return Device::BusPirate::_Future->new( $self );
}

package Device::BusPirate::_Future;
use base qw( Future );
use Carp;

sub new
{
   my $proto = shift;
   my $self = $proto->SUPER::new;
   $self->{bp} = ref $proto ? $proto->{bp} : shift;
   return $self;
}

sub await
{
   my $bp = shift->{bp};

   my $sleep = $bp->{sleep_f};
   my $read = $bp->{read_f}[0];

   my $fh = $bp->{fh};

   croak "Cannot await with nothing to do" unless $sleep or $read;

   my $timeout = $sleep ? $sleep->[0] : undef;
   my $rvec = '';
   vec( $rvec, $fh->fileno, 1 ) = 1 if $read;

   if( select( $rvec, undef, undef, $timeout ) ) {
      my $buf = '';
      while( length $buf < $read->[0] ) {
         $fh->sysread( $buf, $read->[0] - length $buf, length $buf );
      }

      shift @{ $bp->{read_f} };
      $read->[1]->done( $buf );
   }
   else {
      undef $bp->{sleep_f};
      $sleep->[1]->done;
   }
}

=head1 TODO

=over 4

=item *

More modes - bitbang, I2C, UART, 1-wire, raw-wire

=item *

Concept of "chips" - models of attached devices and defined ways to interact
with them. Maybe "chip" isn't the best name for e.g. MIDI over UART or PS/2.

=item *

PWM, AUX frequency measurement and ADC support.

=back

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
