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
use Config::Pit;
use JSON;
use Encode qw/encode_utf8/;

my $config = plugin( 'Config' => { file => "config.pl" } );
my $nt = Net::Twitter::Lite::WithAPIv1_1->new(
    apiurl           => 'http://api.twitter.com/1.1',
    legacy_lists_api => 0,
    consumer_key    => $config->{twitter}->{consumer_key},
    consumer_secret => $config->{twitter}->{consumer_secret},
);

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

get '/auth/auth_twitter' => sub {
    my $self = shift;

    my $session      = Plack::Session->new( $self->req->env );                                
    
    my $verifier = $self->req->param('oauth_verifier');
    my $consumer = OAuth::Lite::Consumer->new(
        consumer_key       => $config->{twitter}->{consumer_key},
        consumer_secret    => $config->{twitter}->{consumer_secret},
        site               => q{http://api.twitter.com},
        request_token_path => q{/oauth/request_token},
        access_token_path  => q{/oauth/access_token},
        authorize_path     => q{/oauth/authorize},
    );
    if (! $verifier) {
        my $request_token = $consumer->get_request_token(
            callback_url => $config->{twitter}->{callback_url}
        );
        $session->set( request_token => $request_token);
        $self->redirect_to( $consumer->url_to_authorize(
            token => $request_token
        ) );
    } else {
        my $request_token = $session->get('request_token');
        my $access_token = $consumer->get_access_token(
            token    => $request_token,
            verifier => $verifier
        );
        $session->remove('request_token');
        my $credentials_res = $consumer->request(
            method => 'GET',
            url    => q{http://api.twitter.com/1/account/verify_credentials.json},
            token  => $access_token,
        );
        my $tw = JSON->new->utf8->decode($credentials_res->decoded_content);
        my $tl_res = $consumer->request(
            method => 'GET',
            url    => 'https://api.twitter.com/1.1/statuses/home_timeline.json',
            token  => $access_token,
        );
        my $timeline = decode_json($tl_res->decoded_content);
        warn Dumper encode_utf8($timeline->{text});
        $self->stash->{screen} = $tw->{screen_name};

    }

};

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


builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session',                      store  => 'File';
    app->start;
}
