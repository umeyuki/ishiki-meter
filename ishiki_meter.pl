#!/usr/bin/env perl
use Mojolicious::Lite;
use Plack::Builder;
use Plack::Session;
use Data::Dumper::Concise;
use DBI;
use DBIx::TransactionManager;
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

app->secret( $config->{secret} );


helper redis => sub {
    Redis->new( %{ $config->{Redis} } );
};

helper dbi => sub {
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
        my $sth = $self->dbh->prepare($sql);
        $sth->execute();
        my $rows = $sth->fetchall_arrayref( {} );
        for my $row (@$rows) {
            $keywords->{ $row->{name} } = { id => $row->{id}, value => $row->{value} };
        }
        
        $self->redis->set( 'keywords' , Dumper($keywords) );
        $sth->finish;
        $self->dbh->disconnect;
    }
    $keywords;
};

helper keyword_map => sub {
    my ($self) = shift;

    #TODO use redis
    my $keywords = eval $self->redis->get('keyword_map') || {};
    unless ( %$keywords ) {
        my $sql = <<SQL;
SELECT
    id,name,value
FROM
    keywords
SQL
        my $sth = $self->dbh->prepare($sql);
        $sth->execute();
        my $rows = $sth->fetchall_arrayref( {} );
        for my $row (@$rows) {
            $keywords->{ $row->{id} } =  $row->{name};
        }
        
        $self->redis->set( 'keyword_map' , Dumper($keywords) );
        $sth->finish;
        $self->dbh->disconnect;
    }
    $keywords;
};


helper ishiki => sub {
    Ishiki::Calculator->new( );
};

helper create_user => sub {
    my ($self,$user,$authenticated_by) = @_;

    # usersテーブルに追加
    # authenticated_by,remote_id,name,profile_image_url
    my $sql = <<SQL;
INSERT OR IGNORE
INTO
  users(authenticated_by,remote_id,name,profile_image_url,created,updated)
VALUES
  (?,?,?,?,?)
SQL
    my $sth =$self->dbh->prepare($sql);
    $sth->bind_param(1,$authenticated_by);
    $sth->bind_param(2,$user->{id}); 
    $sth->bind_param(3,$user->{name}); 
    $sth->bind_param(4,$user->{profile_image_url});
    $sth->execute;
    $sth->finish;
    $self->dbh->sqlite_last_insert_rowid()
;

helper create_page => sub {
    my ($self,$user_id,$ishiki,$used_keywords) = @_;

    # pagesを作成
    # ishiki int, keywords_html text
    #

    # 表示用htmlを作成
    my @html;
    my $base_html = <<HTML;
<li class="rank"><a href="https://twitter.com/search?q=%s" >%s</a></li>
HTML
    for my $keyword ( @{$used_keywords} ){
        push @html,sprintf($base_html,$used_keywords->{$keyword},$keyword,$keyword);
    }
    
    my $sql = <<SQL;
INSERT
INTO
  pages(user_id,ishiki,html)
VALUES
  (?,?,?);
SQL
    my $sth = $self->dbh->prepare($sql);
    $sth->bind_param(1,$user_id);
    $sth->bind_param(2,$ishiki);
    $sth->bind_param(3,@html);
    $sth->execute;
    $sth->finish;
};

helper show_page => sub {
    my ( $self, $page_id) = @_;

    my $sql = <<SQL;
SELECT
  user_name,authenticated_by,remort_id
FROM
  pages
WHERE


SQL
        

};

helper show_keywords => sub {
    my ($self, $page_id) = @_;

    my $page_keywords = eval $self->redis->get('page_keywords' . $page_id ) || [];

    unless ( @$page_keywords > 0 ) {
        # redisになければsqlite3から取得
        my $sql = <<SQL;
SELECT
  keyword_id
FROM
  page_keywords
WHERE
  page_id = ?;
SQL
        my $sth = $self->dbh->prepare($sql);
        $sth->bind_param(1,$page_id);
        $sth->execute();

        my $keywords = $self->{keywords};
        my $rows = $sth->fetchall_arrayref({});

        my $keyword_map = $self->keyword_map;
        for my $row ( @$rows ) {
            push @$page_keywords, $keyword_map->{$row->{keyword_id}};
        }
        $self->redis->set( 'page_keywords_' . $page_id  , Dumper($page_keywords) );
    }    
    \$page_keywords;
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
        my @messages = ( $profile,@tweets );

        my ( $ishiki,$used_keywords,$populars ) = $self->ishiki->calc( \@messages, $self->keywords );
        my $tm = DBIx::TransactionManager->new($self->dbh);↲        
        #       $self->create_user($user,'twitter');
        #       $self->create_page($user,$ishiki,$used_keywords);
        
#        my $page_id = $self->create_page($user,$ishiki,$used_keywords);
        
#        $self->popular_keyword($used_keywords);
#        $self->update_populars($populars); use redis
        
        $session->set( 'user'        => $user );
        $session->set( 'ishiki'      => $ishiki );
        $session->set( 'used_keywords'    => $used_keywords );
#        my $page_id = $self->create($ishiki,);
#        $self->redirect_to('/' . $page_id);
        $self->redirect_to('/' );
         
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
        my ( $ishiki,$used_keywords,$populars ) = $self->ishiki->calc( \@messages, $self->keywords );
#        my $page_id = $self->create_page($user,$ishiki,$used_keywords);
#        $self->popular_keyword($used_keywords);
#        $self->update_populars($populars); use redis
        
        $session->set( 'user'        => $user );
        $session->set( 'ishiki'      => $ishiki );
        $session->set( 'used_keywords'    => $used_keywords );
#        my $page_id = $self->create($ishiki,);
#        $self->redirect_to('/' . $page_id);
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
    $self->stash->{'pages'} = $self->show_page($page_id);
    
    $self->render( page => $self->param('id') );
};


builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session',                      store  => 'File';
    app->start;
}
