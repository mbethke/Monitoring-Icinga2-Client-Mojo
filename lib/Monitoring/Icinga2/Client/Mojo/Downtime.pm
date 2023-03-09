package Monitoring::Icinga2::Client::Mojo::Downtime;

use strictures 2;
use Mojo::Base 'Monitoring::Icinga2::Client::Mojo::Message';

our $DESC = [ qw/ code status legacy_id name / ];

1;
