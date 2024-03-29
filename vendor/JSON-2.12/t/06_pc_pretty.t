#! perl

# copied over from JSON::PC and modified to use JSON
# copied over from JSON::XS and modified to use JSON

use strict;
use Test::More;
BEGIN { plan tests => 9 };

BEGIN { $ENV{PERL_JSON_BACKEND} = 0; }

use JSON;

my ($js,$obj,$json);
my $pc = new JSON;

$obj = {foo => "bar"};
$js = $pc->encode($obj);
is($js,q|{"foo":"bar"}|);

$obj = [10, "hoge", {foo => "bar"}];
$pc->pretty (1);
$js = $pc->encode($obj);
is($js,q|[
   10,
   "hoge",
   {
      "foo" : "bar"
   }
]|);

$obj = { foo => [ {a=>"b"}, 0, 1, 2 ] };
$pc->pretty(0);
$js = $pc->encode($obj);
is($js,q|{"foo":[{"a":"b"},0,1,2]}|);


$obj = { foo => [ {a=>"b"}, 0, 1, 2 ] };
$pc->pretty(1);
$js = $pc->encode($obj);
is($js,q|{
   "foo" : [
      {
         "a" : "b"
      },
      0,
      1,
      2
   ]
}|);

$obj = { foo => [ {a=>"b"}, 0, 1, 2 ] };
$pc->pretty(0);
$js = $pc->encode($obj);
is($js,q|{"foo":[{"a":"b"},0,1,2]}|);


$obj = {foo => "bar"};
$pc->indent(3); # original -- $pc->indent(1);
is($pc->encode($obj), qq|{\n   "foo":"bar"\n}|, "nospace");
$pc->space_after(1);
is($pc->encode($obj), qq|{\n   "foo": "bar"\n}|, "after");
$pc->space_before(1);
is($pc->encode($obj), qq|{\n   "foo" : "bar"\n}|, "both");
$pc->space_after(0);
is($pc->encode($obj), qq|{\n   "foo" :"bar"\n}|, "before");

