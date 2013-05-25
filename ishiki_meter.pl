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
use Config::Pit;

my $config = plugin( 'Config' => { file => "config.pl" } );
my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
    apiurl           => 'http://api.twitter.com/1.1',
    legacy_lists_api => 0,
    consumer_key    => $config->{twitter}->{consumer_key},
    consumer_secret => $config->{twitter}->{consumer_secret},
);
warn Dumper $config;
app->secret( $config->{secret} );

helper keywords => sub {
    my ( $self ) = shift;
    
};

helper ishiki => sub {
    my ( $self ) = shift;
    my $app_id = $config->{yahoo}->{app_id};

    Ishiki::Parser->new( yahoo_appid => $app_id );
};

=head2 twitter oauth

set session twitter profile and recently 20 tweets

=cut

plugin 'Web::Auth',
    module      => 'Twitter',
    key         => $config->{twitter}->{consumer_key},
    secret      => $config->{twitter}->{consumer_secret},
    on_finished => sub {
        my ($c, $access_token, $access_secret, $user) = @_;
        my $session = Plack::Session->new( $c->req->env );
        $nt->access_token($access_token);
        $nt->access_token_secret($access_token);

        my $tweets = $nt->user_timeline(
            {
                count        => $config->{twitter}->{count},
                screen_name  => $user->{screen_name}
            }
        );
        $session->set('screen_name' => $user->{screen_name} );
        $session->set('description' => $user->{description} );
        $session->set('remarks'     => $tweets );
        
        $c->redirect_to('/');
    };

plugin 'Web::Auth',
    module      => 'Facebook',
    key         => $config->{facebook}->{app_id},
    secret      => $config->{facebook}->{secret},
    on_finished => sub {
        my ( $c, $access_token,$user ) = @_;
        my $session = Plack::Session->new( $c->req->env );
        
        my $fb = Facebook::Graph->new(
            access_token => $access_token
        );
        warn Dumper $access_token;
        warn Dumper $user;
        my $posts = $fb->fetch('me/posts')->{data};

        for my $post ( @$posts ) {
            warn "message:";
            warn $post->{message};
        }
        $session->set('screen_name' => $user->{name} );
        $session->set('description' => $user->{bio} );
        #        $session->set( 'remarks'     => $tweets );

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
    my ($screen_name,$description,$remarks);

    if ($session->get('screen_name') ) {
        $screen_name = $session->get('screen_name');
        $description = $session->get('description');
        $remarks     = $session->get('remarks');
        $self->ishiki->calc($screen_name,$description,$remarks);
    }

    
    # twitter
    if ( $session->get('access_token') && $session->get('access_token_secret') ) {
        $nt->access_token( $session->get('access_token') );
        $nt->access_token_secret( $session->get('access_token_secret') );

        # parse profile
        $self->{ishiki} = $self->ishiki->calc($description);
        
        # parse tweets
        $self->{ishiki} = $self->parse_tweet($screen_name);
    }
    
    $self->stash->{screen_name} = $screen_name;
    $self->stash->{description} = $description;
    $self->stash->{screen_name} = $screen_name;
    $self->stash->{ishiki}      = $self->{ishiki};
    $self->render('index');
};

get '/logout' => sub {
    my $self    = shift;
    my $session = Plack::Session->new( $self->req->env );
    $session->expire();
    $self->redirect_to('/');
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
