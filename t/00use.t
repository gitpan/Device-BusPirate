#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use_ok( 'Device::BusPirate' );

use_ok( 'Device::BusPirate::Mode::SPI' );

done_testing;
