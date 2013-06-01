#!/usr/bin/env perl
use Mojolicious::Lite;
use LWP::Protocol::Net::Curl;
use Net::Twitter::Lite::WithAPIv1_1;
use Facebook::Graph;
use Plack::Builder;
use Plack::Session;
use Data::Dumper::Concise;
use DBI;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use Ishiki::Parser;
use Carp;
use OAuth::Lite::Consumer;

use JSON;
use Redis;
use Encode qw/encode_utf8/;

my $config = plugin( 'Config' => { file => "config.pl" } );
my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
    apiurl           => 'http://api.twitter.com/1.1',
    legacy_lists_api => 0,

    consumer_key     => $config->{twitter}->{consumer_key},
    consumer_secret  => $config->{twitter}->{consumer_secret},
);

app->secret( $config->{secret} );


helper redis => sub {
    Redis->new( %{ $config->{Redis} } );
};

helper keywords => sub {
    my ($self) = shift;

    #TODO use redis
    my $keywords = {};    # || $self->redis->get('KEYWORDS');;
    if ( keys %$keywords <= 0 ) {
        my $dbh = DBI->connect( @{ $config->{DBI} } );
        $dbh->{unicode} = 1;
        my $sql = <<SQL;
SELECT
    name,value
FROM
    keywords
SQL
        my $sth = $dbh->prepare($sql);
        $sth->execute();
        my $rows = $sth->fetchall_arrayref( {} );
        for my $row (@$rows) {
            $keywords->{ $row->{name} } = $row->{value};
        }

        #        $self->redis->rpush( 'KEYWORDS' , $_ ) for (@$keywords);
        $sth->finish;
        $dbh->disconnect;
    }

    $keywords;
};

helper ishiki => sub {
    my $self = shift;
    my $app_id = $config->{yahoo}->{app_id};

    Ishiki::Parser->new( yahoo_appid => $app_id );
};

helper pickup_words => sub {
    my ($self,$remarks) = @_;

    my @result = ();
    my @keywords = keys %{$self->{keywords}};

    for my $remark ( @$remarks ) {
        for my $keyword ( @keywords ) {
            if ( $remark =~ /$keyword/ ){
                my $font = $self->{keywords}->{$keyword} * 20;
                $remark =~ s|$keyword|<span style=\"font-size:${font}px;color:red\">$keyword</span>|;
            }
        }

        push @result ,$remark;
    }
    return \@result;
};

=head2 twitter oauth


=cut

sub startup {
    my $self = shift;

    my $r = $self->routes;
    $r->route('/')->via('GET')->to('index#index');
}

get '/auth/auth_twitter' => sub {
    my $self = shift;

    if ( my $denied = $self->req->param('denied') ){
        $self->redirect_to( "/?error=access_denied" );
        return;
    }
    

    my $session = Plack::Session->new( $self->req->env );

    my $verifier = $self->req->param('oauth_verifier');
    my $consumer = OAuth::Lite::Consumer->new(
        consumer_key       => $config->{twitter}->{consumer_key},
        consumer_secret    => $config->{twitter}->{consumer_secret},
        site               => q{http://api.twitter.com},
        request_token_path => q{/oauth/request_token},
        access_token_path  => q{/oauth/access_token},
        authorize_path     => q{/oauth/authorize},
    );

    if ( not $verifier ) {
        my $request_token = $consumer->get_request_token(
            callback_url => $config->{twitter}->{callback_url} );
        $session->set( request_token => $request_token );
        $self->redirect_to(
            $consumer->url_to_authorize(
                token => $request_token
            )
        );
    }
    else {
        my $request_token = $session->get('request_token');
        my $access_token  = $consumer->get_access_token(
            token    => $request_token,
            verifier => $verifier
        );
        $session->remove('request_token');
        my $credentials_res = $consumer->request(
            method => 'GET',
            url => q{http://api.twitter.com/1/account/verify_credentials.json},
            token => $access_token,
        );
        my $user = JSON->new->utf8->decode( $credentials_res->decoded_content );
        my $tl_res = $consumer->request(
            method => 'GET',
            url    => 'https://api.twitter.com/1.1/statuses/user_timeline.json',
            token  => $access_token,
            params => { count => 10 }
        );
        my $timeline = decode_json( $tl_res->decoded_content );
        my @tweets   = ();

        for my $tweet ( @{$timeline} ) {
            push @tweets, $tweet->{text};
        }

        $session->set( 'screen_name' => $user->{name} );
        $session->set( 'profile'     => $user->{description} );
        $session->set( 'remarks'     => \@tweets );
        $self->redirect_to('/');
    }

};

get '/' => sub {
    my $self = shift;

    my $error = $self->req->param('error');
    $self->render( error => $error );

    
    $self->{keywords} = $self->keywords;    
    my $session = Plack::Session->new( $self->req->env );

    my ( $screen_name, $profile, $remarks, $ishiki );

    if ( $session->get('screen_name') ) {
        $screen_name = $session->get('screen_name');
        $profile     = $session->get('profile');
        $remarks     = $session->get('remarks');
        
        my @data = ( $profile, @$remarks );
        my $keywords = $self->{keywords};
        warn "keyword!";
        warn Dumper $keywords;
        $ishiki = $self->ishiki->calc( \@data, $self->{keywords} );
    }
    $self->stash->{screen_name} = $screen_name;
    $self->stash->{profile}     = $profile;
    $self->stash->{remarks}     = $self->pickup_words($remarks);
    $self->stash->{ishiki}      = $ishiki;
    $self->render('index');
};

get '/logout' => sub {
    my $self    = shift;
    my $session = Plack::Session->new( $self->req->env );
    $session->expire();
    $self->redirect_to('/');
};

builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session',                      store  => 'File';
    app->start;
}
