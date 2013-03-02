#!/usr/bin/env perl
use Mojolicious::Lite;
use Net::Twitter::Lite;
use Plack::Builder;
use Plack::Session;
use YAML::Tiny::Color;

# Documentation browser under "/perldoc"
plugin 'PODRenderer';

my $config = plugin('Config' => { file => "config.pl"});
my $nt     = Net::Twitter::Lite->new(
    consumer_key    => $config->{consumer_key},
    consumer_secret => $config->{consumer_secret},
);
app->secret($config->{secret});

get '/' => sub {
  my $self = shift;
  my $session = Plack::Session->new( $self->req->env );
  my $profile;

  my $description = [];
  if ($session->get('access_token')) {
      $nt->access_token( $session->get('access_token') );
      $nt->access_token_secret( $session->get('access_token_secret') );
      $description = $nt->all_subscriptions();
  }
  $self->stash->{description} = $description;
  $self->stash->{screen_name} = $session->get('screen_name');
  $self->stash->{ishiki}   = '';
  $self->render('index');
};

get '/login' => sub {
    my $self = shift;
    my $session = Plack::Session->new( $self->req->env);
    my $url     = $nt->get_authorization_url(
        callback => $self->req->url->base . '/callback' );
    $session->set('token', $nt->request_token );
    $session->set('token_secret', $nt->request_token_secret);
    $self->redirect_to($url);
};

get '/callback' => sub {
    my $self = shift;
    unless( $self->req->param('denied')) {
        my $session = Plack::Session->new( $self->req->env );
        $nt->request_token( $session->get('token'));
        $nt->request_token_secret( $session->get('token_secret') );
        my $verifier = $self->req->param('oauth_verifier');
        my ( $access_token, $access_token_secret, $user_id, $screen_name ) =
          $nt->request_access_token( verifier => $verifier );
        $session->set( 'access_token',        $access_token );
        $session->set( 'access_token_secret', $access_token_secret );
        $session->set( 'screen_name',         $screen_name );
    }
};

get '/logout' => sub {
    my $self = shift;
    my $session = Plack::Session->new( $self->req->env );
    $session->expire();
    $self->redirect_to('/');
};
    
get '/vote' => sub {
    # ログイン後3つまで投票できる
};

    
builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session', store => 'File';
    app->start;
}
__DATA__

@@ index.html.ep
% layout 'default';
% title 'Welcome';
Welcome to the Mojolicious real-time web framework!

@@ layouts/default.html.ep
<!DOCTYPE html>
<html>
  <head><title><%= title %></title></head>
  <body><%= content %></body>
</html>
