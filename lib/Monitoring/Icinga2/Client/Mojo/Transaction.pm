package Monitoring::Icinga2::Client::Mojo::Transaction;

use strictures 2;
use Mojo::Base 'Mojo::Transaction::HTTP';
use Carp;
use namespace::clean;

has 'i2_retries';

sub new {
    my ($class, $self, $retries) = @_;
    bless $self, $class;
    $self->i2_retries( $retries );
    return $self;
}

1;

