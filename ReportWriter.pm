package HTML::ReportWriter;

use strict;
use DBI;
use CGI;
use Template;
use lib qw(..);
use HTML::ReportWriter::PagingAndSorting;

our $VERSION = '0.9.1';

=head1 NAME

HTML::ReportWriter - Simple OO interface to generate pageable, sortable HTML tabular reports

=head1 SYNOPSIS

 #!/usr/bin/perl -w

 use strict;
 use HTML::ReportWriter;
 use CGI;
 use Template;
 use DBI;

 my $dbh = DBI->connect('DBI:mysql:foo', 'bar', 'baz');

 # The simplest possible method of calling RW...
 my $report = HTML::ReportWriter->new({
		DBH => $dbh,
		DEFAULT_SORT => 'name',
		SQL_FRAGMENT => 'FROM person AS p, addresses AS a WHERE a.person_id = p.id',
		COLUMNS => [ 'name', 'address1', 'address2', 'city', 'state', 'zip' ],
 });

 $report->draw();

=head1 DESCRIPTION

This module generates an HTML tabular report. The first row of the table is the header,
which will contain column names, and if the columns are sortable, the name will link back
to the cgi, and will allow for changing of the sort. Below the table of results is a paging
table, which shows the current page, along with I<n> other pages of the total result set, 
and includes links to the first, previous, next and last pages in the result set.

The results are drawn directly from the data in the database, however their appearance may 
be overridden in one of two ways:

1. Change the template (aka point the ReportWriter at a different template) (NOT YET IMPLEMENTED)
2. use SQL to modify the results before they are displayed.

Almost everything in this module is configurable; see the documentation for B<new()>, below.

=head1 METHODS

=over

=item B<new($options)>

Documentation forthcoming.

=cut

sub new
{
    my ($pkg, $args) = @_;

    my @paging_args = (
            'RESULTS_PER_PAGE',
            'PAGES_IN_LIST',
            'PAGE_VARIABLE',
            'SORT_VARIABLE',
            'DEFAULT_SORT',
            'PREV_HTML',
            'NEXT_HTML',
            'FIRST_HTML',
            'LAST_HTML',
            'ASC_HTML',
            'DESC_HTML',
            );
    my $paging_args = {};

    # check for required arguments
    if(!defined($args->{'DBH'}))
    {
        die 'Argument \'DBH\' is required';
    }
    elsif(!defined($args->{'SQL_FRAGMENT'}))
    {
        die 'Argument \'SQL_FRAGMENT\' is required';
    }
    elsif(!defined($args->{'COLUMNS'}) || ref($args->{'COLUMNS'}) ne 'ARRAY')
    {
        die 'Argument \'COLUMNS\' is required, and must be an array reference';
    }

    # argument setup
    $args->{'COLUMN_SORT_DEFAULT'} = 1 if !defined $args->{'COLUMN_SORT_DEFAULT'};
    $args->{'MYSQL_MAJOR_VERSION'} = 4 if !defined $args->{'MYSQL_MAJOR_VERSION'};
    $args->{'FONT_COLOR'} = 'black' if !defined $args->{'FONT_COLOR'};
    $args->{'HIGHLIGHT_COLOR'} = '#555555' if !defined $args->{'HIGHLIGHT_COLOR'};

    # check for simplified column definition, and make sure the COLUMNS array isn't empty
    # if the simplified definition is used, change it to the complex one.
    if(@{$args->{'COLUMNS'}})
    {
        my $size = @{$args->{'COLUMNS'}};
        foreach my $index (0..$size)
        {
            if(ref($args->{'COLUMNS'}->[$index]) eq 'SCALAR')
            {
                my $str = $args->{'COLUMNS'}->[$index];
                $args->{'COLUMNS'}->[$index] = {
                    'sql' => $str,
                    'get' => $str,
                    'display' => ucfirst($str),
                    'sortable' => ($args->{'COLUMN_SORT_DEFAULT'} ? 1 : 0),
                };
            }
        }
    }
    else
    {
        die 'COLUMNS can not be a blank array ref';
    }

    # create a CGI object if we haven't been given one
    if(!defined($args->{'CGI_OBJECT'}) || !UNIVERSAL::isa($args->{'CGI_OBJECT'}, "CGI"))
    {
        $args->{'CGI_OBJECT'} = new CGI;
        warn "Creating new CGI object";
    }

    # set up the arguments for the paging module, and delete them from the main arg list,
    # since we don't really care about them
    foreach my $key (@paging_args)
    {
        if(defined $args->{$key})
        {
            $paging_args->{$key} = $args->{$key};
            delete $args->{$key};
        }
    }

    # the paging module also gets a CGI_OBJECT, and a copy of the COLUMNS setup
    $paging_args->{'CGI_OBJECT'} = $args->{'CGI_OBJECT'};
    $paging_args->{'SORTABLE_COLUMNS'} = $args->{'COLUMNS'};

    # instantiate our paging object
    $args->{'PAGING_OBJECT'} = HTML::ReportWriter::PagingAndSorting->new($paging_args);

    # default HTML-related arguments
    if(!defined $args->{'PAGE_TITLE'})
    {
        $args->{'PAGE_TITLE'} = "HTML::ReportWriter v${VERSION} generated report";
    }
    if(!defined $args->{'HTML_HEADER'})
    {
        $args->{'HTML_HEADER'} = '';
    }
    if(!defined $args->{'HTML_FOOTER'})
    {
        $args->{'HTML_FOOTER'} = '<center><div id="footer"><p align="center">This report was generated using <a href="http://search.cpan.org/~opiate/">HTML::ReportWriter</a> version ' . $VERSION . '.</p></div></center>';
    }

    my $self = bless $args, $pkg;

    return $self;
}

=item B<draw()>

Draws the page. Template stored as __DATA__ inside this module.

=cut

sub draw
{
	my $self = shift;
    my $template = Template->new();

    my @fields = map { $_->{'sql'} } @{$self->{'COLUMNS'}};

    my $vars = {
        'HIGHLIGHT_COLOR' => $self->{'HIGHLIGHT_COLOR'},
        'FONT_COLOR' => $self->{'FONT_COLOR'},
        'VERSION' => $VERSION,
        'HTML_HEADER' => $self->{'HTML_HEADER'},
        'HTML_FOOTER' => $self->{'HTML_FOOTER'},
        'PAGE_TITLE' => $self->{'PAGE_TITLE'},
        'results' => [],
    };

    ### CORE LOGIC
    if($self->{'MYSQL_MAJOR_VERSION'} >= 4)
    {
        my $sql = 'SELECT SQL_CALC_FOUND_ROWS ' . join(', ', @fields) . ' ' . $self->{'SQL_FRAGMENT'};
        my $sort = $self->{'PAGING_OBJECT'}->get_mysql_sort();
        my $limit = $self->{'PAGING_OBJECT'}->get_mysql_limit();

        my $sth = $self->{'DBH'}->prepare("$sql $sort $limit");
        $sth->execute();
        my ($count) = $self->{'DBH'}->selectrow_array('SELECT FOUND_ROWS() AS num');

        my $result = $self->{'PAGING_OBJECT'}->num_results($count);

        while(my $href = $sth->fetchrow_hashref)
        {
            push @{$vars->{'results'}}, $href;
        }
    }
    else
    {
        # implement handling for MySQL 3 -- needs to generate a count(*) query first, run it
        # then grab the results once it has set num_results
        die "Not yet implemented";
    }
    # END CORE LOGIC

    foreach (0..$#fields)
    {
        if($fields[$_] =~ / AS /i)
        {
            $fields[$_] =~ s/^.+ AS (.+)$/$1/i;
        }
        elsif($fields[$_] =~ /^[a-zA-Z0-9]+\./)
        {
            $fields[$_] =~ s/^[a-zA-Z0-9]+\.//;
        }
    }

    $vars->{'PAGING'} = $self->{'PAGING_OBJECT'}->get_paging_table();
    $vars->{'SORTING'} = $self->{'PAGING_OBJECT'}->get_sortable_table_header();
    $vars->{'FIELDS'} = \@fields;

    print $self->{'CGI_OBJECT'}->header;
    $template->process(\*DATA, $vars) || warn "Template processing failed: " . $template->error();
}

=back

=head1 TODO

=over

=item *
documentation

=item *
Allos the user to pass arguments to Template, or allow the user to pass a previously created
Template object (in the fashion of the CGI and DBH objects.

=item *
write tests for the module

=item *
implement logic for MySQL versions prior to 4

=item *
fix handling for MySQL 4 in case of paging past end of results

=item *
break the CSS style into an override-able argument

=item *
support for other databases (help greatly appreciated)

=back

=head1 BUGS

None are known about at this time.

Please report any additional bugs discovered to the author.

=head1 SEE ALSO

This module relies on L<DBI>, L<Template> and L<CGI>.
The paging/sorting module also relies on L<POSIX> and L<List::MoreUtils>.

=head1 AUTHOR

Shane Allen E<lt>opiate@gmail.comE<gt>

=head1 ACKNOWLEDGEMENTS

=over

=item *
PagingAndSorting was developed during my employ at HRsmart, Inc. L<http://www.hrsmart.com> and its
public release was graciously approved.

=item *
Bob: helped with design of the ReportWriter module with regards to rendering the results, and
indirectly suggested a simplified COLUMNS definition.

=back

=head1 COPYRIGHT

Copyright 2004, Shane Allen. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

__DATA__
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html>
<head><title>[% PAGE_TITLE %]</title></head>
<body>

<style type="text/css">

#footer {
    clear: both;
    padding: 5px;
    margin-top: 5px;
    border: 1px solid gray;
    background-color: rgb(213, 219, 225);
    width: 600px;
}

.paging-table {
    border: 0px solid black;
}
.paging-td {
    padding: 4px;
    font-weight: none;
    color: [% HIGHLIGHT_COLOR %];
}
.paging-a {
    color: [% FONT_COLOR %];
    font-weight: bold;
    text-decoration: none;
}

#idtable {
        border: 1px solid #666;
}

#idtable tbody tr td {
        padding: 3px 8px;
        font-size: 8pt;
        border: 0px solid black;
        border-left: 1px solid #c9c9c9;
        text-align: center;
}

#idtable tbody tr.table_even td {
        background-color: #eee;
}

#idtable tbody tr.table_odd td {
        background-color: #fff;
}

#idtable tbody tr.sortable-header-tr td {
        background-color: #bbb;
}
</style>
[% HTML_HEADER %]
[% rowcounter = 1 %]
<center>
<table border="0" width="800">
<tr><td>
<table id="idtable" border="0" cellspacing="0" cellpadding="4" width="100%">
[% SORTING %]
[%- IF results.size < 1 %]
<tr><td colspan="[% FIELDS.size %]" align="center">There are no results to display.</td></tr>
[%- ELSE %]
    [%- FOREACH x = results %]
        [%- IF rowcounter mod 2 %]
            [%- rowclass = "table_odd" %]
        [%- ELSE %]
            [%- rowclass = "table_even" %]
        [%- END %]
<tr class="[% rowclass %]">
        [%- FOR field = FIELDS %]
    <td>[% x.$field %]</td>
        [%- END %]
</tr>
        [%- rowcounter = rowcounter + 1 %]
    [%- END %]
[%- END %]
</table>
</td></tr>
<tr><td>
<table border="0" width="100%">
<tr>
<td width="75%"></td><td width="25%">[% PAGING %]</td>
</tr>
</table>
</td></tr>
</table>
</center>
<br /><br />
[% HTML_FOOTER %]
</body>
</html>
