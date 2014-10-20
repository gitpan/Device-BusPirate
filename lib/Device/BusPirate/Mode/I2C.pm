#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2014 -- leonerd@leonerd.org.uk

package Device::BusPirate::Mode::I2C;

use strict;
use warnings;
use base qw( Device::BusPirate::Mode );

our $VERSION = '0.05';

use Carp;

use Future::Utils qw( repeat );

use constant MODE => "I2C";

=head1 NAME

C<Device::BusPirate::Mode::I2C> - use C<Device::BusPirate> in I2C mode

=head1 DESCRIPTION

This object is returned by a L<Device::BusPirate> instance when switching it
into C<I2C> mode. It provides methods to configure the hardware, and interact
with one or more I2C-attached chips.

=cut

my $EXPECT_ACK = sub {
   my ( $buf ) = @_;
   $buf eq "\x01" x length $buf or
      return Future->fail( 1 );
   return Future->done;
};

=head1 METHODS

The following methods documented with a trailing call to C<< ->get >> return
L<Future> instances.

=cut

# Not to be confused with start_bit
sub start
{
   my $self = shift;

   $self->_start_mode_and_await( "\x02", "I2C" )->then( sub {
      $self->pirate->read( 1 )
   })->then( sub {
      ( $self->{version} ) = @_;
      return Future->done( $self );
   });
}

=head2 $i2c->start_bit->get

Sends an I2C START bit transition

=cut

sub start_bit
{
   my $self = shift;

   $self->pirate->write( "\x02" );
   $self->pirate->read( 1 )->then( $EXPECT_ACK )
      ->else_fail( "Expected ACK response to I2C start_bit" );
}

=head2 $i2c->stop_bit->get

Sends an I2C STOP bit transition

=cut

sub stop_bit
{
   my $self = shift;

   $self->pirate->write( "\x03" );
   $self->pirate->read( 1 )->then( $EXPECT_ACK )
      ->else_fail( "Expected ACK response to I2C stop_bit" );
}

=head2 $i2c->write( $bytes )->get

Sends the given bytes over the I2C wire. This method does I<not> send a
preceding start or a following stop; you must do that yourself, or see the
C<send> and C<recv> methods.

=cut

sub write
{
   my $self = shift;
   my ( $bytes ) = @_;

   my @chunks = $bytes =~ m/(.{1,16})/gs;

   repeat {
      my $bytes = shift;

      my $len_1 = length( $bytes ) - 1;

      $self->pirate->write( chr( 0x10 | $len_1 ) . $bytes );

      $self->pirate->read( 1 )->then( sub {
         my ( $buf ) = @_;
         $buf eq "\x01" or return Future->fail( "Expected ACK response during I2C write" );

         $self->pirate->read( length $bytes )
      })->then( sub {
         my ( $buf ) = @_;
         $buf =~ m/^\x00+/;
         $+[0] == length $bytes and return Future->done;
         Future->fail( "Received NACK after $+[0] bytes" );
      });
   } foreach => \@chunks,
     while => sub { not shift->failure },
     otherwise => sub { Future->done };
}

=head2 $bytes = $i2c->read( $length )->get

Receives the given number of bytes over the I2C wire, sending an ACK bit after
each one but the final, to which is sent a NACK.

=cut

sub read
{
   my $self = shift;
   my ( $length ) = @_;

   my $ret = "";

   repeat {
      my $ack = shift;
      $self->pirate->write( "\x04" );
      $self->pirate->read( 1 )->then( sub {
         $ret .= $_[0];
         $self->pirate->write( $ack ? "\x06" : "\x07" );
         $self->pirate->read( 1 )->then( $EXPECT_ACK )
            ->else_fail( "Expected ACK response to I2C ack_bit" );
      });
   } foreach => [ (1) x ($length-1), 0 ],
     otherwise => sub { Future->done( $ret ) };
}

=head2 $i2c->send( $address, $bytes )->get

A convenient wrapper around C<start_bit>, C<write> and C<stop_bit>. This
method sends a START bit, then an initial byte to address the slave in WRITE
mode, then the remaining bytes, followed finally by a STOP bit. This is
performed atomically by using the C<enter_mutex> method.

C<$address> should be an integer, in the range 0 to 0x7f.

=cut

sub send
{
   my $self = shift;
   my ( $address, $bytes ) = @_;

   $address >= 0 and $address < 0x80 or
      croak "Invalid I2C slave address";

   $self->pirate->enter_mutex( sub {
      $self->start_bit->then( sub {
         $self->write( chr( $address << 1 | 0 ) . $bytes )
      })->then( sub {
         $self->stop_bit;
      });
   });
}

=head2 $bytes = $i2c->recv( $address, $length )->get

A convenient wrapper around C<start_bit>, C<write>, C<read> and C<stop_bit>.
This method sends a START bit, then an initial byte to address the slave in
READ mode, then reads the given number of bytes, followed finally by a STOP
bit. This is performed atomically by using the C<enter_mutex> method.

C<$address> should be an integer, in the range 0 to 0x7f.

=cut

sub recv
{
   my $self = shift;
   my ( $address, $length ) = @_;

   $address >= 0 and $address < 0x80 or
      croak "Invalid I2C slave address";

   $self->pirate->enter_mutex( sub {
      $self->start_bit->then( sub {
         $self->write( chr( $address << 1 | 1 ) )
      })->then( sub {
         $self->read( $length )
      })->then( sub {
         my ( $bytes ) = @_;
         $self->stop_bit->then_done( $bytes );
      });
   });
}

=head1 AUTHOR

Paul Evans <leonerd@leonerd.org.uk>

=cut

0x55AA;
