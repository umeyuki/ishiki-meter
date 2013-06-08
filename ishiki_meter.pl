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
use Ishiki::Calculator;
use Carp;
use OAuth::Lite::Consumer;
use URI;
use Digest::SHA;
use Furl;

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

helper furl => sub {
    my $self = shift;
    Furl::HTTP->new;
};

helper json => sub {
    my $self = shift;
    JSON->new;
};

helper keywords => sub {
    my ($self) = shift;

    #TODO use redis
    my $keywords = eval $self->redis->get('keywords') || {};
    unless ( %$keywords ) {
        my $dbh = DBI->connect( @{ $config->{DBI} } );
        $dbh->{sqlite_unicode} = 1;
        my $sql = <<SQL;
SELECT
    id,name,value
FROM
    keywords
SQL
        my $sth = $dbh->prepare($sql);
        $sth->execute();
        my $rows = $sth->fetchall_arrayref( {} );
        for my $row (@$rows) {
            $keywords->{ $row->{name} } = { id => $row->{id}, value => $row->{value} };
        }
        
        $self->redis->set( 'keywords' , Dumper($keywords) );
        $sth->finish;
        $dbh->disconnect;
    }
    $keywords;
};

helper ishiki => sub {
    Ishiki::Calculator->new( );
};



helper page_create => sub {
    # ページを作成 
    
};

helper popular => sub {
    
};

sub startup {
    my $self = shift;

    my $r = $self->routes;
    $r->route('/')->via('GET')->to('index#index');
}

get '/' => sub {
    my $self = shift;

    my $error = $self->req->param('error');
    $self->render( error => $error );

    $self->{keywords} = $self->keywords;    
    my $session = Plack::Session->new( $self->req->env );

    my ( $screen_name, $user, $profile, $ishiki, $used_keywords );
    
    if ( $session->get('user') && keys %{$session->get('user')} > 0 ) {
        $user          = $session->get('user');
        $ishiki        = $session->get('ishiki');
        $used_keywords = $session->get('used_keywords');        
    }
    warn Dumper $ishiki;
    warn "hogehoge";
    warn Dumper $used_keywords;

    $self->stash->{user}        = $user;
    $self->stash->{keywords}    = $used_keywords;
    $self->stash->{ishiki}      = $ishiki;
    $self->render('index');
};

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
        my $user = $self->json->utf8->decode( $credentials_res->decoded_content );
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

        my $profile = $user->{description};
        my @sentenses = ( $profile,@tweets );

        my ( $ishiki,$used_keywords,$populars ) = $self->ishiki->calc( \@sentenses, $self->keywords );
#        $self->create_page($ishiki,$processed_sentenses);
#        $self->update_populars($populars); use redis
        $session->set( 'user'        => $user );
        $session->set( 'ishiki'      => $ishiki );
        $session->set( 'used_keywords'    => $used_keywords );
#        my $page_id = $self->create($ishiki,);
#        $self->redirect_to('/' . $page_id);
        $self->redirect_to('/');
         
    }

};

get '/auth/auth_fb' => sub {
    my $self = shift;

    my $session = Plack::Session->new( $self->req->env );
    
    my $req = $self->req;
    my $code = $req->param('code');
    my $error = $req->param('error');
    if ( $error ) {
        if ( 'access_denied' eq $error ) {
            $self->redirect_to( "/?error=$error");
            return;
        }
    } elsif ( ! $code ) {
        my $fb_state = Digest::SHA::sha1_hex( Digest::SHA::sha1_hex(time(), {}, rand(),$$ ));
        $session->set('fb_s',$fb_state);
        my $uri = URI->new( 'https://www.facebook.com/dialog/oauth');
        $uri->query_form(
            client_id => $self->config->{facebook}->{client_id},
            redirect_uri => 'http://localhost:5000/auth/auth_fb',
            scope => 'read_stream',
            state => $fb_state
        );
        $self->redirect_to( $uri );
    } elsif ( $code ) {
        my $state = $req->param('state');
        my $expected_state = $session->get('fb_s');

        if ( $state ne $expected_state) {
            die "Something wrong";
        }
        my $uri = URI->new( 'https://graph.facebook.com/oauth/access_token' );
        $uri->query_form(
            client_id     => $self->config->{facebook}->{client_id},
            client_secret => $self->config->{facebook}->{client_secret},            
            redirect_uri  => 'http://localhost:5000/auth/auth_fb',
            code => $code
        );

        my (undef, $h_code, undef, $h_hdrs, $h_body );

        for (1..5) {
            eval {
                (undef, $h_code, undef, $h_hdrs, $h_body ) = $self->furl->get($uri);
            };

            last unless $@;
            last if $h_code eq 200;
            select(undef,undef,undef,rand());
        }

        if ( $h_code ne 200 ) {
            die "HTTP request to fetch access token failed: $h_code: $h_body";
        }
        my $res = URI->new("?$h_body");
        my %q = $res->query_form;
        $uri = URI->new('https://graph.facebook.com/me/home');
        $uri->query_form(
            access_token => $q{access_token}
        );
        (undef, $h_code, undef, $h_hdrs, $h_body) = $self->furl->get($uri);
        my $fb = $self->json->decode($h_body);
        warn Dumper $fb;
    } else {
        die;
    }

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
