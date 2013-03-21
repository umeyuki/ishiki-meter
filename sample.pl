#perl!
use Findbin;
use lib "$FindBin::Bin/lib";
use Ishiki;
use YAML::Tiny::Color;
use Config::Pit;
use utf8;
use Config::Pit;

my $config = pit_get(
    "e.developer.yahoo.co.jp",
    require => {
        "app_id" => 'my yahoo app id',
        "secret" => 'my yahoo secret id'
    }
);

my $app_id = $config->{app_id};
warn $app_id;
my $ishiki = Ishiki->new(
    yahoo_appid => $app_id,
);
my $keywords = require 'etc/sample.pl';

my $norns =  $ishiki->get_norn('こんにちは、私の名前はumeyukiです。趣味は登山とです。座右の名は感謝');


my $result = 0;
for my $key ( @$norns  ) {
    if ( my $match = $keywords->{$key}) {
        print $keywords->{$key} . "\n";
        $result += $keywords->{$key};
    }
}

print "Your Ishiki is ${result}";
