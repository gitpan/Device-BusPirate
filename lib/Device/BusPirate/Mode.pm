package Device::BusPirate::Mode;

use strict;
use warnings;

our $VERSION = '0.01';

sub new
{
   my $class = shift;
   my ( $bp ) = @_;

   my $self = bless {
      bp => $bp,
   }, $class;

   return $self;
}

sub pirate
{
   my $self = shift;
   return $self->{bp};
}

sub _start_mode_and_await
{
   my $self = shift;
   my ( $send, $await ) = @_;

   my $pirate = $self->pirate;

   $pirate->write( $send );
   $pirate->read( length $await )->then( sub {
      my ( $buf ) = @_;
      return Future->done( $buf ) if $buf eq $await;
      return Future->fail( "Expected '$await' response but got '$buf'" );
   });
}

0x55AA;
