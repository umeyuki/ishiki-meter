#perl!
use Findbin;
use lib "$FindBin::Bin/lib";
use Ishiki::Calculator;
use YAML::Tiny::Color;
use Config::Pit;
use utf8;


my $config = pit_get(
    "e.developer.yahoo.co.jp",
    require => {
        "app_id" => 'my yahoo app id',
        "secret" => 'my yahoo secret id'
    }
);

my $app_id = $config->{app_id};
my $ishiki = Ishiki::Calculator->new(
    yahoo_appid => $app_id,
);
my $keywords = require 'etc/sample.pl';

my $result =  $ishiki->calc('こんにちは、私の名前はumeyukiです。趣味は登山とです。座右の名は感謝',$keywords);

# my $result = 0;
# for my $word ( @$words  ) {
#     if ( my $match = $keywords->{$word}) {
#         print $keywords->{$word} . "\n";
#         $result += $keywords->{$word};
#     }
# }

print "Your Ishiki is ${result}";
