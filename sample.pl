#perl!
use lib './lib';
use Ishiki;
use YAML::Tiny::Color;

my $ishiki = Ishiki->new(
    yahoo_appid => '',
 );

my $result =  $ishiki->get_norn('こんにちは、私の名前はumeyukiです。趣味は登山です');

warn Dump $result;
