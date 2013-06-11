#!/usr/bin/env perl

use utf8;
use Carp;
use Mojolicious::Lite;
use Plack::Builder;
use Plack::Session;
use Data::Dumper::Concise;
use DBI;
use DBIx::TransactionManager;
use OAuth::Lite::Consumer;
use URI;
use Digest::SHA;
use Furl;
use JSON;
use Redis;
use Try::Tiny;
use Encode qw/encode_utf8/;

my $config = plugin( 'Config' => { file => "config.pl" } );

app->secret( $config->{secret} );

helper redis => sub {
    Redis->new( %{ $config->{Redis} } );
};

helper dbh => sub {
        my $dbh = DBI->connect( @{ $config->{DBI} } );
        $dbh->{sqlite_unicode} = 1;
        $dbh;
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
        my $sql = <<SQL;
SELECT
    id,name,value
FROM
    keywords
SQL
        my $dbh = $self->dbh;
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
    my ( $self,$sentenses,$keywords ) = @_;

    my $ishiki = 0;
    my @processeds = ();
    my %populars = ();
    my %used = ();
    for my $sentense ( @$sentenses ){
        for my $keyword ( keys %{$keywords} ) {
            if ( $sentense =~ /$keyword/i ) {
                my $id    = $keywords->{$keyword}->{id};
                my $value = $keywords->{$keyword}->{value};
                $used{$keyword} = $value;
                $ishiki += $value;
            }
        }
    }
    return $ishiki,\%used;
};

helper process => sub {
    my ($self,$user,$ishiki,$used_keywords) = @_;

    my $page_id;
    my $dbh = $self->dbh;
    try {
        my $tm = DBIx::TransactionManager->new( $dbh );
        {
            my $txn = $tm->txn_scope;
            my $user_id =
                $self->create_user( $user  ) || $self->user_id( $user );
            print "user_id:" . $user_id ."\n";
            $page_id = $self->create_page( $user_id, $ishiki, $used_keywords );
            print "page_id:" . $page_id . "\n";
            $txn->commit;
        }
        # popular keyword ranking
        $self->redis->zincrby('ranking', 1, $_) for keys %$used_keywords;
    } catch {
        warn "caught error: $_";
    }
    $page_id;
};

helper user_id => sub {
    my ( $self, $user  ) = @_;

    my $user_id;
    my $sql = <<SQL;
SELECT
  id
FROM
  users
WHERE
  authenticated_by = ? AND
  remote_id        = ?
SQL
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$user->{authenticated_by});
    $sth->bind_param(2,$user->{remote_id});
    $sth->execute or croak $sth->errstr;
    my $rows = $sth->fetchall_arrayref({});
    # FIXME oneline
    for my $row ( @$rows ) {
        $user_id = $row->{id};
    }
    
    croak 'Select user error!' unless $user_id;
    $dbh->disconnect;
    $user_id;
};
   

helper create_user => sub {
    my ($self,$user) = @_;

    my $sql = <<SQL;
INSERT OR IGNORE
INTO
  users(authenticated_by,remote_id,name,profile_image_url)
VALUES
  (?,?,?,?)
SQL
    my $dbh = $self->dbh; 
    my $sth =$dbh->prepare($sql);

    $sth->bind_param(1,$user->{authenticated_by});
    $sth->bind_param(2,$user->{remote_id}); 
    $sth->bind_param(3,$user->{name}); 
    $sth->bind_param(4,$user->{profile_image_url});
    $sth->execute or croak $sth->errstr;
    $sth->finish;

    my $user_id = $dbh->last_insert_id('ishiki-meter.db','ishiki-meter.db','users','id');
    $dbh->disconnect;
    $user_id;
};

helper create_page => sub {
    my ($self,$user_id,$ishiki,$used_keywords) = @_;

    # 表示用htmlを作成
    my @html;
    my $base_html = <<HTML;
<li class="rank%d"><a href="https://twitter.com/search?q=%s" >%s</a></li>
HTML
    for my $keyword ( keys %{$used_keywords} ){
        push @html,sprintf($base_html,$used_keywords->{$keyword},$keyword,$keyword);
    }
    
    my $sql = <<SQL;
INSERT
INTO
  pages(user_id,ishiki,html)
VALUES
  (?,?,?);
SQL
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$user_id);
    $sth->bind_param(2,$ishiki);
    $sth->bind_param(3,join('',@html));
    $sth->execute or croak $sth->errstr;
    $sth->finish;

    my $page_id = $dbh->last_insert_id('ishiki-meter.db','ishiki-meter.db','pages','id');
    $dbh->disconnect;
    $page_id;
};

helper show_page => sub {
    my ( $self, $page_id) = @_;
    my $sql = <<SQL;
SELECT
  users.name AS name ,
  users.profile_image_url AS image_url,
  pages.ishiki AS ishiki,
  pages.html AS html
FROM
  pages
INNER JOIN
  users ON pages.user_id = users.id
WHERE
  pages.id = ?
SQL

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$page_id);
    $sth->execute or croak $sth->errstr;
    my $rows = $sth->fetchall_arrayref( {} );
    $sth->finish;    

    my %result = ();    
    for my $row ( @$rows ) {
        %result = (
            name               => $row->{name},
            profile_image_url  => $row->{image_url},
            ishiki             => $row->{ishiki},
            html               => $row->{html}
        );
    }
    $dbh->disconnect;
    \%result;
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
        my $tw_user = $self->json->utf8->decode( $credentials_res->decoded_content );
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

        my @messages = ( $tw_user->{description},@tweets );

        my $user = {
            authenticated_by  => 'twitter',
            remote_id         => $tw_user->{id},
            name              => $tw_user->{screen_name},
            profile_image_url => $tw_user->{profile_image_url}
        };
        my ( $ishiki,$used_keywords ) = $self->ishiki( \@messages, $self->keywords );
        my $page_id = $self->process($user,$ishiki,$used_keywords);


        # $session->set( 'user'        => $user );
        # $session->set( 'ishiki'      => $ishiki );
        # $session->set( 'used_keywords'    => $used_keywords );

        $self->redirect_to('/' . $page_id);
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
            redirect_uri => $self->config->{facebook}->{callback_url},
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

        my $user = {};
        my @messages = ();                
        {
            my $uri = URI->new('https://graph.facebook.com/me/');
            $uri->query_form(
                access_token => $q{access_token}
            );
            (undef, $h_code, undef, $h_hdrs, $h_body) = $self->furl->get($uri);
            my $fb = $self->json->decode($h_body);
            my $profile_image_url = sprintf("https://graph.facebook.com/%s/picture",$fb->{id});
            $user = {
                remote_id         => $fb->{id},
                name              => $fb->{name},
                profile           => $fb->{bio},
                profile_image_url => $profile_image_url
            };
        }
        {
            $uri = URI->new('https://graph.facebook.com/me/feed/');
            $uri->query_form(
                access_token => $q{access_token}
            );
            (undef, $h_code, undef, $h_hdrs, $h_body) = $self->furl->get($uri);
            my $fb = $self->json->decode($h_body);

            for my $data ( @{$fb->{data}} ) {
                push @messages, $data->{message} if $data->{message};
            }
        }
        push @messages,$user->{profile};
        my ( $ishiki,$used_keywords,$populars ) = $self->ishiki( \@messages, $self->keywords );
#       $self->process($user,$ishiki,$used_keywords);
        #        $self->popular_keyword($used_keywords);
#        $self->update_populars($populars); use redis
        
        $session->set( 'user'        => $user );
        $session->set( 'ishiki'      => $ishiki );
        $session->set( 'used_keywords'    => $used_keywords );

        $self->redirect_to('/' );
        
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

get '/:id' => sub {
    my $self = shift;

    my $page_id = $self->param('id');
    $self->stash->{content} = $self->show_page($page_id);
    $self->render('show');
};


builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session',                      store  => 'File';
    app->start;
}
