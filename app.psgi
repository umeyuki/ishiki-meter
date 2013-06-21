#!/usr/bin/env perl

use utf8;
use Carp;
use Mojolicious::Lite;
use Plack::Builder;
use Plack::Session;
use Data::Dumper::Concise;
use DBI;
use DBIx::TransactionManager;
use SQL::Maker;
use OAuth::Lite::Consumer;
use URI;
use Digest::SHA qw/sha1_hex/;
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

helper sb => sub {
    my ( $self, $type ) = @_;
    return SQL::Maker->new(driver => 'SQLite') unless $type;
    if ( $type eq 'condition') {
        return SQL::Maker::Condition->new;
    }
    if ( $type eq 'select') {
        return SQL::Maker::Select->new(driver => 'SQLite');
    }
};
    
helper furl => sub {
    Furl::HTTP->new;
};

helper json => sub {
    JSON->new;
};

helper get_keywords => sub {
    my ($self) = shift;

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
            $keywords->{ $row->{name} } = { id => $row->{id}, value => $row->{value}  };
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
    my %used_keywords;

    for my $sentense ( @$sentenses ){
        for my $keyword ( keys %{$keywords} ) {
            if ( $sentense =~ /$keyword/i ) {
                my $id    = $keywords->{$keyword}->{id};
                my $value = $keywords->{$keyword}->{value};
                $used_keywords{$keyword} = {
                    id    => $id,
                    value => $value,
                };
                $ishiki += $value;
            }
        }
    }
    return $ishiki,\%used_keywords;
};

helper process => sub {
    my ($self,$user,$ishiki,$used_keywords) = @_;

    my $entry_id;
    my $dbh  = $self->dbh;
    my $redis = $self->redis;
    try {
        my $tm = DBIx::TransactionManager->new( $dbh );
        {
            my $txn = $tm->txn_scope;
            my $user_id =
                $self->create_user( $dbh,$user  ) || $self->user_id( $user );
            $entry_id = $self->create_entry( $dbh,$user_id, $ishiki, $used_keywords );
            $self->create_entry_keywords($dbh,$entry_id,$user_id,$used_keywords);
            $txn->commit;

            # new ishiki
            $redis->lpush('recent',$entry_id);
            # user ranking
            $redis->zadd('entry_ranking', $ishiki, $entry_id);
            # keyword ranking
            $redis->zincrby('keyword_ranking', 1, $used_keywords->{$_}->{id} ) for keys %$used_keywords;

            return $entry_id;
        }
        $dbh->disconnect;
    } catch {
        warn "caught error: $_";
        $dbh->disconnect;
    }
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
    my ($self,$dbh,$user) = @_;

    my $sql = <<SQL;
INSERT OR IGNORE
INTO
  users(authenticated_by,remote_id,name,profile_image_url)
VALUES
  (?,?,?,?)
SQL
    my $sth =$dbh->prepare($sql);

    $sth->bind_param(1,$user->{authenticated_by});
    $sth->bind_param(2,$user->{remote_id}); 
    $sth->bind_param(3,$user->{name}); 
    $sth->bind_param(4,$user->{profile_image_url});
    $sth->execute or croak $sth->errstr;
    $sth->finish;

    my $user_id = $dbh->last_insert_id('ishiki-meter.db','ishiki-meter.db','users','id');
    $user_id;
};

helper create_entry => sub {
    my ($self,$dbh,$user_id,$ishiki,$used_keywords) = @_;

    # 表示用htmlを作成
    my @html = ();
    my $base_html = <<HTML;
<li class="rank%d"><a href="%s" >%s</a></li>
HTML
    my $link;
    for my $keyword ( keys %{$used_keywords} ){
        $link = sprintf('https://twitter.com/search?q=%s',$keyword);
        push @html,sprintf($base_html,$used_keywords->{$keyword}->{value} ,$link, $keyword);
    }

    my $sql = <<SQL;
INSERT
INTO
  entries(user_id,ishiki,html)
VALUES
  (?,?,?);
SQL
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$user_id);
    $sth->bind_param(2,$ishiki);
    $sth->bind_param(3,join('',@html));
    $sth->execute or croak $sth->errstr;
    $sth->finish;

    my $entry_id = $dbh->last_insert_id('ishiki-meter.db','ishiki-meter.db','entries','id');
    $entry_id;
};

helper create_entry_keywords => sub {
    my ($self,$dbh,$entry_id,$user_id,$used_keywords) = @_;

    SQL::Maker->load_plugin('InsertMulti');
    my $keywords = $self->get_keywords;

    # insert multi用に配列を作成
    my @rows;
    for my $keyword ( keys %$used_keywords )  {
        push @rows,{
            entry_id   => $entry_id,
            user_id    => $user_id,
            keyword_id => $used_keywords->{$keyword}->{id}
        };
    }

    my ( $sql, @binds ) = $self->sb->insert_multi('entry_keywords', \@rows);

    my $sth = $dbh->prepare($sql);
    $sth->execute(@binds);
    $sth->finish;
    
};


sub startup {
    my $self = shift;

    my $r = $self->routes;
    $r->route('/')->via('GET')->to('index#index');
}

# 全ページ共通処理 ランキングサイドバー
under sub {
    my $self = shift;

    # 最も使われているランキング 1週間ごとに更新が望ましい
    $self->{keyword_ranking} = $self->keyword_ranking;    
    # マンスリー意識ランキング entry_idとuser_nameとishikiを表示
    $self->{entry_ranking}   = $self->entry_ranking;
    
    1;
};

helper keyword_ranking => sub {
    my $self = shift;

    my $redis = $self->redis;
    my @rankin_keywords = $redis->zrevrange('keyword_ranking',0,9);

    return unless @rankin_keywords;

    my %ranking;
    # 順位マップ作成 1 => $keyword_id, 2 => $keyword_id
    my $rank = 1;
    for my $keyword_id ( @rankin_keywords ) {
        $ranking{$keyword_id} = $rank;
        $rank++;
    }

    my ( $sql,@binds ) = $self->sb->select('keywords',['id','name'],{ id => \@rankin_keywords},{});
    
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@binds);
    my $rows = $sth->fetchall_arrayref({});

    my %result;
    for my $row ( @$rows ) {
        my $keyword_id  = $row->{id};
        my $name        = $row->{name};
        my $rank        = $ranking{$keyword_id};
        $result{$rank} = {
            id      => $keyword_id,
            name    => $name,
        };
    }
    $sth->finish;
    $dbh->disconnect;
    \%result;
};

helper entry_ranking => sub {
    my $self = shift;

    my $redis = $self->redis;
    my @rankin_entries =  $redis->zrevrange('entry_ranking',0,9);
    return;
    return unless @rankin_entries;

    my %ranking;
    my $rank = 1;
    for my $entry_id ( @rankin_entries ) {
        $ranking{$entry_id} = $rank;
        $rank++;
    }

    my $stmt = $self->sb('select');
    my $condition = $self->sb('condition');

    $stmt->add_select('u.name')->add_select('e.ishiki')->add_select('e.id');
    $stmt->add_join( [ 'entries','e' ]=> {type => 'left', table => 'users u', condition => ['u.id = e.user_id']});    
    $condition->add( id => \@rankin_entries );
    $stmt->set_where($condition);

    my $sql   = $stmt->as_sql;
    my @binds = $stmt->bind;
    
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@binds);

    my %result;
    my $rows = $sth->fetchall_arrayref({});
    for my $row ( @$rows ) {
        my $entry_id  = $row->{'e.id'};
        my $name      = $row->{'u.name'};
        my $ishiki    = $row->{'e.ishiki'};
        my $rank      = $ranking{$entry_id};
        
        $result{$rank} = {
            id      => $entry_id,
            name    => $name,
            ishiki  => $ishiki
        };
    }
    
    \%result;
};

get '/' => sub {
    my $self = shift;

    my $error = $self->req->param('error');
    $self->render( error => $error );

    $self->{keywords} = $self->get_keywords;    
    my $session = Plack::Session->new( $self->req->env );

    my ( $screen_name, $user, $profile, $ishiki, $used_keywords );
    
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
            url => q{http://api.twitter.com/1.1/account/verify_credentials.json},
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
        my ( $ishiki,$used_keywords ) = $self->ishiki( \@messages, $self->get_keywords );
        my $entry_id = $self->process($user,$ishiki,$used_keywords);
        
        # $session->set( 'user'        => $user );
        # $session->set( 'ishiki'      => $ishiki );
        # $session->set( 'used_keywords'    => $used_keywords );
        $self->redirect_to('/' . $entry_id);
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
            redirect_uri  => $self->config->{facebook}->{callback_url},
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
                profile_image_url => $profile_image_url,
                authenticated_by  => 'facebook'
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

        my ( $ishiki,$used_keywords ) = $self->ishiki( \@messages, $self->get_keywords );
        
        $session->set( 'user'        => $user );
        $session->set( 'ishiki'      => $ishiki );
        $session->set( 'used_keywords'    => $used_keywords );

        my $entry_id = $self->process($user,$ishiki,$used_keywords);

        $self->redirect_to('/' . $entry_id  );
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

get '/popular' => sub {
    my $self = shift;

    #
    my $redis = $self->redis;
    
    my @popular_ids = $redis->zrevrange('popular',0,9);
    my @popular_entries;
    for my $entry_id ( @popular_ids ) {
        push @popular_entries,$self->get_entry($entry_id);
    }
    $self->stash->{content} = \@popular_entries;
    $self->render('popular');
};

get '/recent' => sub {
    my $self = shift;

    #
    my @recent_ids = $self->redis->lrange('recent',0,49);
    my @recent_entries;
    for my $entry_id ( @recent_ids ) {
        push @recent_entries,$self->get_entry($entry_id);
    }
    $self->stash->{entries} = \@recent_entries;
    warn Dumper @recent_entries;
    $self->render('recent');
};

# entry page
get '/:entry_id' => sub {
    my $self = shift;

    my $entry_id = $self->param('entry_id');

    # popular
    my $redis = $self->redis;
    $redis->zincrby('popular',1, $entry_id );
    
    $self->stash->{content} = $self->get_entry($entry_id);
    $self->render('show');
};

helper get_entry => sub {
    my ( $self, $entry_id) = @_;
    my $sql = <<SQL;
SELECT
  u.name AS name ,
  u.profile_image_url AS image_url,
  e.ishiki AS ishiki,
  e.html AS html
FROM
  entries e
INNER JOIN
  users u ON e.user_id = u.id
WHERE
  e.id = ?
SQL
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$entry_id);
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
    my $entry_keywords = $self->get_entry_keywords($entry_id);
    $result{keywords} = $entry_keywords;
    \%result;
};

helper get_entry_keywords => sub  {
    my ($self,$entry_id) = @_;

    #TODO 関連アイテム
    my $sql = <<SQL;
SELECT
  k.name AS name,k.value AS value
FROM
  entry_keywords ek
INNER JOIN
  keywords k ON k.id = ek.keyword_id
WHERE
  ek.entry_id = ?
SQL

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$entry_id);
    $sth->execute or croak $sth->errstr;

    my @result;
    my $rows = $sth->fetchall_arrayref( {} );
    $sth->finish;    
    for my $row ( @{$rows}) {
        push @result,{ name => $row->{name}, value => $row->{value} };
    }
    \@result;
};

# keyword辞典
    
get '/keyword/:name' => sub {
    my $self = shift;

    my $content = $self->get_keyword($self->param('name'));
    $self->redirect_to('/') unless keys %$content > 0;

    $self->stash->{content} = $content;
    $self->render('keyword');

};

helper get_keyword => sub {
    my ($self,$name) = @_;

    my $sql = <<SQL;
SELECT
  id,name,description
FROM
  keywords
WHERE name = ?
SQL

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$name);
    $sth->execute;

    my ( $content ) = @{$sth->fetchall_arrayref({})};
    $dbh->disconnect;
        
    $content;
};

builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session',                      store  => 'File';
    app->start;
}
