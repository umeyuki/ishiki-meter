package Ishiki::Calculator;
use strict;
use warnings;
use Carp;
use URI;
use LWP::UserAgent;
use XML::Simple;
use Encode;
use utf8;
use YAML::Tiny::Color;

our $VERSION = '0.01';


sub new {
    my ( $class , %args ) = @_;
    my $self = {
        ua       => LWP::UserAgent->new,
        keywords => $args{keywords},
        config   => do '../../config.pl'
    };
    return bless $self,$class;
}

sub calc {
    my ( $self,$sentenses,$keywords ) = @_;

    my $ishiki = 0;
    my @processeds = ();
    my %populars = ();
    for my $sentense ( @$sentenses ){
        for my $keyword ( keys %{$keywords} ) {
            if ( $sentense =~ /$keyword/i ) {
                my $id    = $keywords->{$keyword}->{id};
                $populars{$id}++;
                my $value = $keywords->{$keyword}->{value};
                $ishiki += $value;
                
                my $font_size = $value * 20;
                $sentense =~ s|$keyword|<span style=\"font-size:${font_size}px;color:red\">$keyword</span>|i;
            }
        }
        push @processeds, $sentense;        
    }
#    $self->_insert($ishiki,\@processeds);
    return $ishiki,\@processeds,\%populars;
}

sub _insert {
    my ($self,$ishiki,$remarks) = @_;
    $self->_ishiki_insert($ishiki);
    $self->_remarks_insert($remarks);
}

sub _ishiki_insert {


}

sub _remarks_insert {

}

1;
