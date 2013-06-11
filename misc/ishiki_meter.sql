create table users (
  id integer primary key autoincrement,
  authenticated_by text not null,
  remote_id integer not null,
  name text not null,
  profile_image_url text not null,
  created datetime default current_timestamp,
  updated datetime default current_timestamp,
  deleted datetime,
  UNIQUE(authenticated_by,remote_id)
);

create table keywords (
    id integer primary key autoincrement,
    name text not null,
    value integer default 5,
    url text,
    created datetime default current_timestamp,
    updated datetime default current_timestamp,
    deleted text
);

create table pages  (
    id integer primary key autoincrement,
    user_id integer not null,
    ishiki integer not null,
    html text,
    created datetime default current_timestamp,
    updated datetime default current_timestamp,
    deleted text
);

