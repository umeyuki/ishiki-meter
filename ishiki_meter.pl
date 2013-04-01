#!/usr/bin/env perl
use Mojolicious::Lite;
use LWP::Protocol::Net::Curl;
use Net::Twitter::Lite;
use Facebook::Graph;
use Plack::Builder;
use Plack::Session;
use Data::Dumper::Concise;
use Config::Pit;
use utf8;
use FindBin;
use lib "$FindBin::Bin/lib";
use Ishiki::Calculator;


helper update_tag => sub {
    my ( $self, $id ) = @_;
};

helper calc_ishiki => sub {
    my ( $self ) = shift;
    my $config = pit_get(
        'e.developer.yahoo.co.jp',
        require => {
            app_id => 'my yahoo id',
            secret => 'my secret id '
        }
    );
    my $app_id = $config->{app_id};
    return Ishiki->new( yahoo_appid => $app_id );
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
              my ($c, $access_token, $access_secret, $account_info) = @_;
              my $session = Plack::Session->new( $c->req->env );
              $session->set('access_token' => $access_token);
              $session->set('access_secret' => $access_secret);
              $session->set('screen_name' => $account_info->{screen_name} );
              $session->set('description' => $account_info->{description} );              
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
              warn "check";
              warn Dumper $user_info;
              $session->set( 'screen_name', $user_info );
              
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

    if ( $session->get('access_token') && $session->get('access_token_secret') ) {
        $nt->access_token( $session->get('access_token') );
        $nt->access_token_secret( $session->get('access_token_secret') );
    }

    my $screen_name = $session->get('screen_name');
    my $description = $session->get('description');
    my $ishiki = $self->helper;
    
    
    $self->stash->{screen_name} = $screen_name;
    $self->stash->{description} = $description;
    $self->stash->{screen_name} = $screen_name;
    $self->stash->{ishiki}      = '';
    $self->render('index');
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

