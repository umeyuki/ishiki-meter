#!/usr/bin/env perl
use Mojolicious::Lite;
use LWP::Protocol::Net::Curl;
use Net::Twitter::Lite;
use Facebook::Graph;
use Plack::Builder;
use Plack::Session;
use Data::Dumper::Concise;


helper update_tag => sub {
    my ( $self, $id ) = @_;
};

helper calc_ishiki => sub {
    my ( $self, $id ) = @_;
};

my $config = plugin( 'Config' => { file => "config.pl" } );
my $nt = Net::Twitter::Lite->new(
    consumer_key    => $config->{twitter}->{consumer_key},
    consumer_secret => $config->{twitter}->{consumer_secret},
);
app->secret( $config->{secret} );

plugin 'Web::Auth',
          module      => 'Twitter',
          key         => $config->{twitter}->{consumer_key},
          secret      => $config->{twitter}->{consumer_secret},
          on_finished => sub {
              my ( $c, $access_token, $access_secret ) = @_;
              $c->redirect_to('/');
              
          };

plugin 'Web::Auth',
          module      => 'Facebook',
          key         => $config->{facebook}->{consumer_key},
          secret      => $config->{facebook}->{consumer_secret},
          on_finished => sub {
              my ( $c, $access_token,$user_info ) = @_;
              my $session = Plack::Session->new( $c->req->env );
              $session->set( 'access_token', $access_token );
              $session->set( 'token', $user_info );
#              my $fb = Facebook::Graph->new();
#              my $user = $fb->fetch($user_info->{id});
              $c->redirect_to('/');
          };

sub startup {
    my $self = shift;
    my $session      = Plack::Session->new( $self->req->env );                                

    my $r = $self->routes;
    $r->route('/')->via('GET')->to('index#index');
}

get '/' => sub {
    my $self = shift;

    my $session      = Plack::Session->new( $self->req->env );
    my $subscription = [];
    my $profile;

    my $screen_name = $session->get('screen_name');
    if ( $session->get('access_token') ) {
        $nt->access_token( $session->get('access_token') );
        $nt->access_token_secret( $session->get('access_token_secret') );

    }
    $self->stash->{profile}     = $profile;
    $self->stash->{screen_name} = $screen_name;
    $self->stash->{ishiki}      = '';
    $self->render('index');
};

get '/login' => sub {
    my $self    = shift;
    my $session = Plack::Session->new( $self->req->env );
    my $url     = $nt->get_authorization_url(
        callback => $self->req->url->base . '/callback' );
    $session->set( 'token',        $nt->request_token );
    $session->set( 'token_secret', $nt->request_token_secret );
    $self->redirect_to($url);
};

get '/callback' => sub {
    my $self = shift;
    unless ( $self->req->param('denied') ) {
        my $session = Plack::Session->new( $self->req->env );
        $nt->request_token( $session->get('token') );
        $nt->request_token_secret( $session->get('token_secret') );
        my $verifier = $self->req->param('oauth_verifier');
        my ( $access_token, $access_token_secret, $user_id, $screen_name ) =
          $nt->request_access_token( verifier => $verifier );
        $session->set( 'access_token',        $access_token );
        $session->set( 'access_token_secret', $access_token_secret );
        $session->set( 'screen_name',         $screen_name );
    }
    $self->redirect_to('/');
};

get '/logout' => sub {
    my $self    = shift;
    my $session = Plack::Session->new( $self->req->env );
    $session->expire();
    $self->redirect_to('/');
};

get '/vote' => sub {

    # ログイン後3つまで投票できる
};

get '/auth/twitter' => sub {
    my $self = shift;
    $self->redirect_to('/auth/twitter/authenticate');
};

get '/auth/facebook' => sub {
    my $self = shift;
    $self->redirect_to('/auth/facebook/authenticate');
};


builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session',                      store  => 'File';
    app->start;
}
__DATA__

