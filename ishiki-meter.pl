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
use Time::Piece;

my $config = plugin( 'Config' => { file => "config.pl" } );

app->secret( $config->{secret} );

# sqlite3 dateをエポック時間に変換
helper epoch => sub {
    my ($self,$date) = @_;
    my $t = Time::Piece->strptime($date,'%Y-%m-%d %H:%M:%S');
    $t->epoch;
};

# 1日以上の時間差があればfalseを返す
helper validate_time => sub {
    my ( $self, $before, $now ) = @_;
    my $epoch = $now - $before;
    return $epoch > 86400 ? 1 : 0;
};
    
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
WHERE
  deleted IS NULL
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

helper level => sub {
    my ( $self, $ishiki ) = @_;

    my $redis = $self->redis;

    my $top_entry_id = shift $redis->zrevrange('entry_ranking',0,0);    
    my $high_ishiki = $self->get_ishiki($top_entry_id);


    my $ratio = sprintf("%.2f",$ishiki / $high_ishiki) * 100;

    #TODO マジックナンバー修正
    my $level = 0;
    if ( $ratio == 0 ) {
        $level = 1;
    } elsif ( $ratio >= 100 ) {
        $level = 7;
    } elsif ( $ratio > 80 ) {
        $level = 6;
    } elsif ( $ratio > 60 ) {
        $level = 5;
    } elsif ( $ratio > 40 ) {
        $level = 4;
    } elsif ( $ratio > 20 ) {
        $level = 3;
    } else {
        $level = 2;
    }
    $level
};

helper process => sub {
    my ($self, $user_id, $user, $ishiki,$used_keywords) = @_;
    
    my $entry_id;
    my $dbh  = $self->dbh;
    my $redis = $self->redis;
    
    try {
        my $tm = DBIx::TransactionManager->new( $dbh );
        {
            my $txn = $tm->txn_scope;
            $user_id =
                $self->create_user( $dbh,$user  ) unless $user_id;
            # 既にエントリーが存在し、1日以内であれば警告して終了
            $entry_id = $self->create_entry( $dbh,$user_id, $ishiki, $used_keywords );
            $self->create_entry_keywords($dbh,$entry_id,$user_id,$used_keywords);
            $txn->commit;
            
            # 新着意識に追加
            $redis->lpush('recent',$entry_id);
            # ユーザランキングに追加
            $redis->zadd('entry_ranking', $ishiki, $entry_id);
            # 人気キーワードに追加
            $redis->zincrby('keyword_ranking', 1, $used_keywords->{$_}->{id} ) for keys %$used_keywords;
            
            return $entry_id;
        }
        $dbh->disconnect;
    } catch {
        warn "caught error: $_";
        $dbh->disconnect;
    }
};

helper before_entry_time => sub  {
    my ( $self, $user_id ) = @_;

    my $sql = <<SQL;
SELECT
  created
FROM
  entries
WHERE
  user_id = ?
AND
  deleted IS NULL
ORDER BY created DESC
LIMIT 1
SQL
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$user_id);
    $sth->execute or croak $sth->errstr;
    my $rows = $sth->fetchall_arrayref({});
    my $created = $rows->[0]->{created};

    $self->epoch($created);
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
  remote_id        = ? AND
  deleted IS NULL
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
    
    $dbh->disconnect;
    $user_id;
};
   

helper create_user => sub {
    my ($self,$dbh,$user) = @_;

    my $sql = <<SQL;
INSERT OR IGNORE
INTO
  users(authenticated_by,remote_id,name,profile_image_url,created,updated)
VALUES
  (?,?,?,?,datetime('now', 'localtime'),datetime('now', 'localtime'))
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
    my $link;

    my $sql = <<SQL;
INSERT
INTO
  entries(user_id,ishiki,created,updated)
VALUES
  (?,?,datetime('now', 'localtime'),datetime('now', 'localtime'));
SQL
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$user_id);
    $sth->bind_param(2,$ishiki);
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

    $self->stash->{base_url} = $config->{base_url};
    
    # 最も使われているランキング 1週間ごとに更新が望ましい
    $self->stash->{keyword_ranking} = $self->keyword_ranking;    

    # ユーザ数
    my $user_count = $self->get_user_count;
    $self->stash->{user_count}   = $user_count;

    # エントリー数
    my $entry_count = $self->get_entry_count;
    $self->stash->{entry_count}   = $entry_count;

    $self->stash->{request_uri} = $self->req->url->path;

    # 最高位
    my $redis = $self->redis;
    my $top_entry_id = shift $redis->zrevrange('entry_ranking',0,0);

    # 意識ランキング
    
    $self->stash->{top_entry_id} = $top_entry_id;
    $self->stash->{top_ishiki} = $self->get_ishiki($top_entry_id) || 500;
    
    1;
};

helper get_ishiki => sub {
    my ($self,$entry_id) = @_;
    
    my $dbh =$self->dbh;

    my $sql = <<SQL;
SELECT ishiki FROM entries WHERE id = ? AND deleted IS NULL;
SQL
    my ($ishiki)  = $dbh->selectrow_array($sql,{},$entry_id);
    
    $ishiki;
};


helper comma => sub {
    my $num = $_[1];
    $num = reverse $num;
    $num =~ s/(\d\d\d)(?=\d)(?!\d\.)/$1,/g;
    return scalar reverse $num;
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

    my ( $sql,@binds ) = $self->sb->select('keywords',['id','name','description'],{ id => \@rankin_keywords},{});
    
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@binds);
    my $rows = $sth->fetchall_arrayref({});

    my @result;
    for my $row ( @$rows ) {
        my $keyword_id  = $row->{id};
        my $name        = $row->{name};
        my $description = $row->{description} || '';
        my $rank        = $ranking{$keyword_id};
        push @result, {
            id          => $keyword_id,
            name        => $name,
            description => length($description) >= 9 ? sprintf( " %s..", substr( $description, 0, 9) ) : $description,
            rank        => $rank
        };
    }
    @result = sort {$a->{rank} <=> $b->{rank} } @result;
    
    # 配列で並べ変え
    
    
    $sth->finish;
    $dbh->disconnect;
    \@result;
};

helper entry_ranking => sub {
    my $self = shift;

    my $redis = $self->redis;
    
    my @entry_ids = $redis->zrevrange('entry_ranking',0,9);
    my $entries = $self->get_entries(\@entry_ids);
    
    my %ranking;
    my $rank = 1;    
    for my $entry_id ( @entry_ids ) {
        $ranking{$entry_id} = $rank;
        $rank++;
    }
    
    my @result;
    for my $entry ( @$entries ) {
        $result[$ranking{$entry->{entry_id}} - 1] = $entry;
    }
    
    \@result;
};

helper get_user_count => sub {
    my $self = shift;

    my $dbh =$self->dbh;

    my $sql = <<SQL;
SELECT COUNT(*) FROM users WHERE deleted IS NULL;
SQL
    my ($count)  = $dbh->selectrow_array($sql);
    
    $dbh->disconnect;
    $count;
};

helper get_entry_count => sub {
    my $self = shift;

    my $dbh =$self->dbh;

    my $sql = <<SQL;
SELECT COUNT(*) FROM entries WHERE deleted IS NULL;
SQL
    my ($count)  = $dbh->selectrow_array($sql);
    
    $dbh->disconnect;
    $count;
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
            params => { count => 20 }
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
        
        # 新出キーワードがあればcompletedフラグをたてる
        $self->complete($used_keywords);
        
        my $user_id =
            $self->user_id( $user );
        if ( $user_id ) {
            # 前回投稿から1日たっていない場合は警告して終了
            my $before_time = $self->before_entry_time($user_id);
            if ( $before_time && not $self->validate_time( $before_time,localtime->epoch ) ) {
                $self->flash( message => '意識解析は1日1回まで可能です。1日経ってから再度お試し下さい(:');
                return $self->redirect_to('/');
            }
        }

        my $entry_id = $self->process($user_id, $user, $ishiki,$used_keywords);

        $self->redirect_to('/' . $entry_id);
    }

};

# 未出現のキーワードにcompleteフラグをつける

helper complete => sub {
    my ( $self, $keywords ) = @_;

    my @keyword_ids = map { $keywords->{$_}->{id} } keys %$keywords;

    my $sb = SQL::Maker->new( driver => 'mysql' );

    my %set = (
        completed => \"datetime('now', 'localtime')"
    );
    my %where = (
        id => { 'IN' => \@keyword_ids},
        completed => \'IS NULL'
    );

    my ($sql,@binds) = $sb->update('keywords',\%set,\%where);
    my $dbh = $self->dbh;
    $dbh->do($sql,undef,@binds) or croak $dbh->errstr;

    $dbh->disconnect;
};

# facebook認証 今のところ使わない

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

get '/ranking' => sub {
    my $self = shift;
    
    $self->stash->{entries} = $self->entry_ranking;
    $self->render('ranking');
};


get '/recent' => sub {
    my $self = shift;

    my @entry_ids = $self->redis->lrange('recent',0,8);
    
    $self->stash->{entries} = $self->get_entries(\@entry_ids);
    $self->render('recent');

};

# キーワードリスト
get '/keyword/list' => sub {
    my $self = shift;

    $self->stash->{keyword_list1} = $self->keyword_list($self->alphabet);
    $self->stash->{keyword_list2} = $self->keyword_list($self->a_to_no);
    $self->stash->{keyword_list3} = $self->keyword_list($self->ha_to_n);

    $self->render('keyword_list');
};

helper keyword_list => sub {
    my ( $self, $initials ) = @_;

    my $select = ['id', 'initial_letter', 'name', 'completed'];
    my $where = {
        initial_letter => $initials,
        deleted     => undef
    };
    my $opt = { order_by => 'initial_letter asc' };
    
    my $sb = $self->sb;
    my ( $sql, @binds ) = $sb->select( 'keywords', $select ,$where, $opt );
    
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->execute(@binds);

    my $rows = $sth->fetchall_arrayref({});
    my @result;
    for my $row ( @$rows ) {
        my $completed = $row->{completed} ?  1 : 0;
        push @result, {
            id => $row->{id},
            initial => $row->{initial_letter},
            name    => $row->{name},
            completed => $completed
        };
    }
    $dbh->disconnect;
    \@result;
};

helper alphabet => sub {
    my @alphabet = qw/a b c d e f g h i j k l m n o p q r s t u v w x y z/;
    \@alphabet;
};

helper a_to_no => sub {
    my @a_to_no = qw/あ い う え お か き く け こ さ し す せ そ た ち つ て と な に ぬ ね の/;
    \@a_to_no;
};

helper ha_to_n => sub {
    my @ha_to_no = qw/は ひ ふ へ ほ ま み む め も や ゆ よ ら り る れ ろ わ を ん/;
    \@ha_to_no;
};

# entry page
get '/:entry_id' => sub {
    my $self = shift;

    my $entry_id = $self->param('entry_id');

    return $self->render_not_found unless $entry_id =~ /\d+/;

    my  ( $entry ) = shift $self->get_entries($entry_id);

    $self->stash->{entry} = $entry;
    
    # popular
    my $redis = $self->redis;
    $redis->zincrby('popular',1, $entry_id );

    $self->render('show');
};

helper get_entries => sub {
    my ( $self, $entry_ids ) = @_;

    my $stmt = $self->sb('select');
    my $condition = $self->sb('condition');

    $stmt->add_select('e.id' => 'entry_id');
    $stmt->add_select('e.ishiki' => 'ishiki');
    $stmt->add_select('u.name' => 'user_name');
    $stmt->add_select('u.profile_image_url' => 'image_url');

    $stmt->add_join(
        [ 'entries', 'e' ] => {
            type      => 'inner',
            table     => 'users',
            alias     => 'u',
            condition => 'e.user_id  = u.id'
        }
    );
    
    $condition->add( entry_id => $entry_ids );
    $stmt->set_where($condition);

    my $sql = $stmt->as_sql;
    my @binds = $stmt->bind;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);

    $sth->execute(@binds) or croak $sth->errstr;
    my $rows = $sth->fetchall_arrayref( {} );
    $sth->finish;    

    my @result;
    
    for my $row ( @$rows ) {
        my $entry_id = $row->{entry_id};
        push @result, {
            entry_id           => $entry_id,
            name               => $row->{user_name},
            profile_image_url  => $row->{image_url},
            ishiki             => $row->{ishiki},
            level            => $self->level($row->{ishiki}),
            keywords           => $self->get_entry_keyword($entry_id)
        };
    }
    $dbh->disconnect;
    \@result;
};

helper get_entry_keyword => sub  {
    my ($self,$entry_id) = @_;


    my $sql = <<SQL;
SELECT
  k.name AS name ,k.value AS value
FROM
  entry_keywords ek
INNER JOIN
  keywords k
ON
  k.id = ek.keyword_id  
WHERE
  ek.entry_id = ?
AND
  k.deleted IS NULL
AND
  ek.deleted IS NULL
SQL
    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$entry_id);
    $sth->execute or croak $sth->errstr;

    my $rows = $sth->fetchall_arrayref({});
    my @result;
    for my $row ( @$rows ) {
        push @result, { name => $row->{name}, value => $row->{value}};
    }
    
    $dbh->disconnect;
    \@result;
};

# keyword辞典
    
get '/keyword/:name' => sub {
    my $self = shift;

    my $keyword = $self->get_keyword($self->param('name'));
    my $related_products = $self->get_products( $keyword->{id} );
    $self->redirect_to('/') unless keys %$keyword > 0;

    $self->stash->{keyword} = $keyword;
    $self->stash->{related_products} = $related_products;
    $self->render('keyword');

};

helper get_keyword => sub {
    my ($self,$name) = @_;

    my $sql = <<SQL;
SELECT
  id,name,description
FROM
  keywords
WHERE
  name = ?
AND
  deleted IS NULL
SQL

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$name);
    $sth->execute;

    my ( $content ) = @{$sth->fetchall_arrayref({})};
    $dbh->disconnect;
        
    $content;
};

helper get_products => sub {
    my ( $self, $keyword_id ) = @_;
    my $sql = <<SQL;
SELECT
  name, image_url, amazon_url, contributer_name
FROM
  related_products
WHERE
  keyword_id = ?
AND
  deleted IS NULL
SQL

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($sql);
    $sth->bind_param(1,$keyword_id);
    $sth->execute;

    my $products = [];
    
    my $rows = $sth->fetchall_arrayref({});
    foreach my $row ( @$rows ) {
        push $products, $row;
    }
    $dbh->disconnect;
    warn 'hello!';
    warn Dumper $products;

    $products;
};

builder {
    enable "Plack::Middleware::AccessLog", format => "combined";
    enable 'Session',                      store  => 'File';
    app->start;
}
