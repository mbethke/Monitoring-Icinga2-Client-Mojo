package Monitoring::Icinga2::Client::Mojo::Message;

use strictures 2;
use Mojo::Base -base;
use Carp;
use Sub::Quote;
use YAML::XS;

has 'orig';

sub new {
    my $class = $_[0];
    $class = ref $class || $class;
    my $desc = do { no strict 'refs'; ${"${class}::DESC"} };
    my $cons;
    if( ref $desc eq 'ARRAY' ) {
        $cons = join( "", map { "$_ => \$_->{$_}," } @$desc );
        $class->attr( $desc );
    } elsif( ref $desc eq 'HASH' ) {
        my @attrs = sort keys %$desc;
        $cons = join( "", map { "$_ => $desc->{$_}," } @attrs );
        $class->attr( \@attrs );
    } else {
        croak("\$${class}::DESC must be arrayref or hashref");
    }

    quote_sub "${class}::new" => qq{
        my \$class = shift; \$_ = shift;
        bless { $cons orig=>\$_ }, \$class;
    };

    no strict 'refs';
    goto &{"${class}::new"}; 
}

1;

