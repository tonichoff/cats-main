package CATS::TeX::Lite;

use strict;
use warnings;

use CATS::TeX::TeXData;

my %generators = (
    var   => sub { qq~<i>$_[0]</i>~ },
    num   => sub { $_[0] },
    op    => sub { join '', @_ },
    spec  => sub { join '', map { $CATS::TeX::TeXData::symbols{$_} || $_ } @_ },
    sup   => sub { qq~<sup>$_[0]</sup>~ },
    'sub' => sub { qq~<sub>$_[0]</sub>~ },
    block => sub { join '', @_ },
);

my $source;


sub sp { $_[0] eq '' ? '' : '&nbsp;' }

sub is_binop { exists $CATS::TeX::TeXData::binary{$_[0]} }


sub parse_token
{
    for ($source)
    {
        # ������� ������ �������� ������������ � &nbsp;
        s/^(\s*)-(\s*)// && return ['op', sp($1), '&minus;', sp($2)];
        s/^(\s*)([+*\/><=])(\s*)// && return ['op', sp($1), $2, sp($3)];
        s/^(\s*)\\([a-zA-Z]+)(\s*)// &&
            return ['spec', (is_binop($2) ? (sp($1), "\\$2", sp($3)) : "\\$2")];
        s/^\s*//;
        s/^([()\[\]])// && return ['op', $1];
        s/^([a-zA-Z]+)// && return ['var', $1];
        s/^([0-9]+(:?\.[0-9]+)?)// && return ['num', $1];
        # ���� ������ ����� ������ ����������
        s/^([.,:;])(\s*)// && return ['op', $1, ($2 eq '' ? '' : ' ')];
        s/^{// && return parse_block();
        s/^(\S)// && return ['num', $1];
    }
}


sub parse_block
{
    my @res = ();
    while ($source ne '')
    {
        last if $source =~ s/^\s*}//;
        if ($source =~ s/^(\s*[_^])//)
        {
            @res or die '!';
            push @res, [$1 eq '_' ? 'sub' : 'sup', parse_token()];
        }
        else
        {
            push @res, parse_token();
        }
    }
    return ['block', @res];
}


sub parse
{
    ($source) = @_;
    return parse_block();
}


sub asHTML
{
    my ($tree) = @_;
    ref $tree eq 'ARRAY' or return $tree;
    my $name = shift(@$tree);
    my @html_params = map { asHTML($_) } @$tree;
    return $generators{$name}->(@html_params);
}


sub convert_one { '<span class="TeX">' . asHTML(parse($_[0])) . '</span>'; }


sub convert_all
{
    $_[0] =~ s/(\$([^\$]*[^\$\\])\$)/convert_one($2)/eg;
}


sub styles() { '' }


#print convert_one('a_1, a_2, \ldots , a_{n+1}');


1;
