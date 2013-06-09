create table users {
  id integer primary key autoincrement,
  authenticated_by text not null,
  remote_id integer not null,
  name text not null.
  profile_image_url text not null,
  created text not null,
  updated text not null,
  deleted text  
}

create table keywords (
    id integer primary key autoincrement,
    name text not null,
    value integer default 5,
    created text not null,
    updated text not null,
    deleted text
);
create table persons (
    id integer primary key autoincrement,
    name text not null,
    amazon url not null,
    created text not null,
    updated text not null,
    deleted text
);

create table populars (
    id integer primary key autoincrement,
    keyword_id integer not null,
    created text not null,
    updated text not null,
    deleted text
);

create table pages  (
    id integer primary key autoincrement,
    ishiki integer not null,
    created text not null,
    updated text not null,
    deleted text
);

create table ishiki_details (
    id integer primary key autoincrement,
    page_id integer,
    kind integer,    
    sort integer,
    text text,
    created text not null,
    updated text not null,
    deleted text
);