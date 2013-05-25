package Ishiki::Parser;
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
    Carp::croak('yahoo_appid is required!!') unless defined $args{yahoo_appid};
    my $base_url = $args{yahoo_base_url} || 'http://jlp.yahooapis.jp/MAService/V1/parse';
    my $self = {
        appid => $args{yahoo_appid},
        base_url => $base_url,
        position => $args{text} || '名詞',
        ua       => LWP::UserAgent->new
    };
    return bless $self,$class;
}

sub _parse {
    my ( $self, $sentence ) = @_;
    Carp::croak 'Sentence is needed!' unless $sentence;

    my $uri = URI->new( $self->{base_url} );
    $uri->query_form( appid => $self->{appid}, sentence => $sentence);
    my $res = $self->{ua}->get($uri);
    Carp::croak $res->status_lin if $res->is_error;

    my $ref = XMLin( $res->content );
    return $sentence unless ref $ref->{ma_result}{word_list}{word} eq 'ARRAY';

    my @result = ();
    for my $word ( @{ $ref->{ma_result}{word_list}{word} }) {
        if ( $word->{pos} eq $self->{position} ) {
            push @result ,$word->{surface};
        }
    }
    return \@result;
}

sub calc {
    my ( $self,$description,$keywords) = @_;

    my $words = $self->_parse($description);
    my $result = 0;
    for my $word ( @$words ){
        if ( $keywords->{$word} ) {
            $result += $keywords->{$word};
        }
    }
    return $result;
}

1;
