package HTML::ReportWriter;

use strict;
use DBI;
use CGI;
use Template;
use HTML::ReportWriter::PagingAndSorting;

our $VERSION = '1.0.1';

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

=head1 METHODS

=over

=item B<new($options)>

Accepts the same arguments as L<HTML::ReportWriter::PagingAndSorting>, plus the following:

=over

=item DBH
A database handle that has connected to the database that the report is to be run against.

=item SQL_FRAGMENT
An SQL fragment starting from the FROM clause, continued through the end of the where clause. In
the case of MySQL and/or other databases that support them, GROUP BY and HAVING clauses may also be
added to the SQL fragment.

=item COLUMNS
Column definitions for what is to be selected. A column definition consists of one of two formats, either
a simple one-element array reference or an array reference of hash references containing the following four
elements:

 get - the string used in the get variable to determine the sorted column
 sql - the sql statement that will select the data from the database
 display - What should be displayed in the column's table header
 sortable - whether or not a sorting link should be generated for the column
 order - the optional sql that will be used to order by the specified column. If not present, then the value of sql is used

These definitions can be arbitrarily complex. For example:

 COLUMNS => [
     {
         get => 'username',
         sql => 'jp.username',
         display => 'Username',
         sortable => 1,
     },
     {
         get => 'date',
         sql => 'DATE_FORMAT(l.created, \'%m/%e/%Y\') AS date',
         display => 'Date',
         sortable => 1,
         order => 'l.created',
     },
     {
         get => 'type',
         sql => "IF(l.deleted = 'yes', 'delete', 'add') AS type",
         display => 'Type',
         sortable => 1,
     },
 ]

and

 COLUMNS => [ 'name', 'address', 'age' ]

are both valid definitions. Additionally, you can combine scalar and hashref-filled arrayrefs, like

 COLUMNS => [
     'name',
     'age',
     {
         get => 'birthday',
         sql => 'DATE_FORMAT(birthday, \'%m/%e/%Y\') AS birthday',
         display => 'Birthday',
         sortable => 1,
         order => 'birthday',
     },
 ]


If you are going to use complex structures in a column definiton (for example, the
DATE_FORMAT and IF statements above), it is STRONGLY recommended that you use a column alias (for example, the
'AS date' in the date column example) in order to ensure proper functionality. This module has not been tested
with unaliased complex columns.

NOTE: If you use formatting that would change a numeric-type column into a string-type column (for example the
date columns above), you should use the order attribute to ensure proper ordering. For example using DATE_FORMAT
as shown above results in the integer-style date column being treated as a string (20041010120000 becomes 
'10-10-2004'), which would cause '10-10-2004' to sort before '10-02-2004'.

=item COLUMN_SORT_DEFAULT
If the simplified version of the COLUMNS definition is used (COLUMNS => [ 'foo', 'bar' ]), then this variable
determines whether the table header will allow sorting of any columns. It is global in scope; that is, either
every column is sortable, or every column is not. If the hashref method is used to define columns, this variable
will be ignored.

=item MYSQL_MAJOR_VERSION
Currently either 3, 4 or 5. Determines which method of determining num_results is used. In MySQL 4 a new method
was added which makes the process much more efficient. Defaults to 4 since it's been the stable release for well
over a year.

=item CGI_OBJECT
A handle to a CGI object. Since it is very unlikely that a report will ever be just a static report with no
user interaction, it is assumed that the coder will want to instantiate their own CGI object in order to allow
the user to interact with the report. Use of this argument will prevent needless creation of additional CGI objects.

=item PAGE_TITLE
The title of the current page. Defaults to "HTML::ReportWriter v${VERSION} generated report".

=item CSS
The CSS style applied to the page. Can be an external stylesheet reference or an inline style. Has a default inline
style that I won't waste space listing here.

=item HTML_HEADER
The first thing that will appear in the body of the HTML document. Unrestricted, can be anything at all. I recommend
placing self-referential forms here to allow the user to interact with the report (for example, setting date ranges).
See B<EXAMPLES> below for ideas.

=item HTML_FOOTER
Last thing that appears in the body of the page. Defaults to: '<center><div id="footer"><p align="center">This report
was generated using <a href="http://search.cpan.org/~opiate/">HTML::ReportWriter</a> version ' . $VERSION . '.</p></div>
</center>';

=back

The return of this function is a reference to the object. Calling draw after the object's initialization will draw the page.

Note with regards to DEFAULT_SORT: the string used to specify the default sort must match the B<get> parameter of the COLUMNS
definition if you use a hashref COLUMN definition.

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
    if(!defined $args->{'CSS'})
    {
        $args->{'CSS'} = "<style type=\"text/css\">\n\n#footer {\n    clear: both;\n    padding: 5px;\n    margin-top: 5px;\n    border: 1px solid gray;\n    background-color: rgb(213, 219, 225);\n    width: 600px;\n}\n\n.paging-table {\n    border: 0px solid black;\n}\n.paging-td {\n    padding: 4px;\n    font-weight: none;\n    color: #555555;\n}\n.paging-a {\n    color: black;\n    font-weight: bold;\n    text-decoration: none;\n}\n\n#idtable {\n        border: 1px solid #666;\n}\n\n#idtable tbody tr td {\n        padding: 3px 8px;\n        font-size: 8pt;\n        border: 0px solid black;\n        border-left: 1px solid #c9c9c9;\n        text-align: center;\n}\n\n#idtable tbody tr.table_even td {\n        background-color: #eee;\n}\n\n#idtable tbody tr.table_odd td {\n        background-color: #fff;\n}\n\n#idtable tbody tr.sortable-header-tr td {\n        background-color: #bbb;\n}\n</style>\n";
    }

    my $self = bless $args, $pkg;

    return $self;
}

=item B<draw()>

Draws the page. This function writes the HTTP header and the page text to STDOUT; it has no return value.

=cut

sub draw
{
	my $self = shift;
    my $template = Template->new();

    my @fields = map { $_->{'sql'} } @{$self->{'COLUMNS'}};

    my $vars = {
        'VERSION' => $VERSION,
        'CSS' => $self->{'CSS'},
        'HTML_HEADER' => $self->{'HTML_HEADER'},
        'HTML_FOOTER' => $self->{'HTML_FOOTER'},
        'PAGE_TITLE' => $self->{'PAGE_TITLE'},
        'results' => [],
    };

    my $loop_counter = 0;

    ### CORE LOGIC
    if($self->{'MYSQL_MAJOR_VERSION'} >= 4)
    {
        my $sql = 'SELECT SQL_CALC_FOUND_ROWS ' . join(', ', @fields) . ' ' . $self->{'SQL_FRAGMENT'};
        my $sort = $self->{'PAGING_OBJECT'}->get_mysql_sort();
        my $limit = $self->{'PAGING_OBJECT'}->get_mysql_limit();

        my $sth = $self->{'DBH'}->prepare("$sql $sort $limit");
        $sth->execute();
        my ($count) = $self->{'DBH'}->selectrow_array('SELECT FOUND_ROWS() AS num');

        my $status = $self->{'PAGING_OBJECT'}->num_results($count);

        # if $count is 0, then there are no results and the check should be skipped. Else, if there are rows and num_results
        # returns false, then we've somehow paged past the end of the result set. Get back on track here.
        while(!$status && $count)
        {
            $limit = $self->{'PAGING_OBJECT'}->get_mysql_limit();

            $sth->finish;
            $sth = $self->{'DBH'}->prepare("$sql $sort $limit");
            $sth->execute();
            ($count) = $self->{'DBH'}->selectrow_array('SELECT FOUND_ROWS() AS num');

            $status = $self->{'PAGING_OBJECT'}->num_results($count);

            # if we aren't back on track in 3 loops, we've got a problem
            if(++$loop_counter == 3)
            {
                die "Unrecoverable error -- is the result set changing?";
            }
        }

        while(my $href = $sth->fetchrow_hashref)
        {
            push @{$vars->{'results'}}, $href;
        }
    }
    else
    {
        # MySQL 3.23 requires the use of a count query -- SQL_CALC_FOUND_ROWS had not yet been implemented
        my $countsql = 'SELECT count(*) ' . $self->{'SQL_FRAGMENT'};
        my $sth = $self->{'DBH'}->prepare("$countsql");
        $sth->execute();
        my ($count) = $sth->fetchrow_array;
        $sth->finish;

        # We won't bother checking the status, cause we're just now generating the limit clause
        $self->{'PAGING_OBJECT'}->num_results($count);

        my $sql = 'SELECT ' . join(', ', @fields) . ' ' . $self->{'SQL_FRAGMENT'};
        my $sort = $self->{'PAGING_OBJECT'}->get_mysql_sort();
        my $limit = $self->{'PAGING_OBJECT'}->get_mysql_limit();

        $sth = $self->{'DBH'}->prepare("$sql $sort $limit");
        $sth->execute();

        while(my $href = $sth->fetchrow_hashref)
        {
            push @{$vars->{'results'}}, $href;
        }
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
Proof-read the documentation. I don't know how soon I'll have time to proofread, so I'm
releasing as-is. Docs should be good enough for the average developer.

=item *
Allow the user to pass arguments to Template, or allow the user to pass a previously created
Template object (in the fashion of the CGI and DBH objects.

=item *
write tests for the module

=item *
support for other databases (help greatly appreciated)

=back

=head1 EXAMPLES

Example 1, a simple non-interactive report, like one that might be used to show phonebook
entries:

 #!/usr/bin/perl -w

 use strict;
 use HTML::ReportWriter;
 use DBI;

 my $dbh = DBI->connect('DBI:mysql:host=localhost:database=testing', 'username', 'password');

 my $sql_fragment = 'FROM people WHERE active = 1';

 my $report = HTML::ReportWriter->new({
         DBH => $dbh,
         SQL_FRAGMENT => $sql_fragment,
         DEFAULT_SORT => 'birthday',
         COLUMNS => [
            'name',
            'age',
            'birthday',
            {
                get => 'phone',
                sql => 'phone_number',
                display => 'Phone Number',
                sortable => 0,
            },
         ],
 });

 $report->draw();

Example 2, an interactive report, using a simple pre-emptive login module for authentication, and
allowing the user to select data within a date range.

 #!/usr/bin/perl -w

 use strict;
 # I am hoping to release the next module soon. Check CPAN if you're interested
 use CGI::Auth::Simple;
 use CGI;
 use HTML::ReportWriter;
 use DBI;

 my $dbh = DBI->connect('DBI:mysql:host=localhost:database=testing', 'test', 'pass');
 my $co = CGI->new();

 my $auth = CGI::Auth::Simple->new({
         DBH => $dbh,
         CGI_OBJECT => $co,
 });
 $auth->login;

 # set defaults if there is not a setting for date1 or date2
 my $date1 = $co->param('date1') || '20050101000000';
 my $date2 = $co->param('date2') || '20050201000000';

 my $sql_fragment = 'FROM log AS l, user AS u WHERE l.user_id = u.id AND u.group_id = '
                  . $dbh->quote($auth->{'profile'}->{'group_id'}) . ' AND l.date BETWEEN '
                  . $dbh->quote($date1) . ' AND ' . $dbh->quote($date2);

 my $report = HTML::ReportWriter->new({
         DBH => $dbh,
         CGI_OBJECT => $co,
         DEFAULT_SORT => 'date',
         HTML_HEADER => '<form method="get"><table><tr><td colspan="3">Show results from:</td></tr><tr>
                         <td><input type="text" name="date1" value="' . $date1 . '" /></td>
                         <td>&nbsp;&nbsp;to&nbsp;&nbsp;</td>
                         <td><input type="text" name="date2" value="' . $date2 . '" /></td></tr></table></form>',
         PAGE_TITLE => 'Log Activity for Group ' . $auth->{'profile'}->{'group_name'},
         COLUMNS => [
             'name',
             'activity',
             {
                 get => 'date',
                 sql => 'DATE_FORMAT(l.created, \'%m/%e/%Y\') AS date',
                 display => 'Date',
                 sortable => 1,
             },
         ],
 });

 $report->draw();

Caveats for Example 1:

=over

=item *
It has not been tested; I wrote it at the same time as the rest of the docs. I have no reason to believe, however
that it would not work given the proper database structure.

=back

Caveats for Example 2:

=over

=item *
It has not been tested; I wrote it at the same time as the rest of the docs. I believe it would work as expected,
however I wouldn't be suprised to learn of a bug/typo in the example. Please keep in mind that this the examples
are primarily intended to illustrate usage. I think the examples both accomplish this goal, regardless of function. :)

=item *
By using the short form of the column definitions, you are asserting that there is only
one column named 'name' and one column named 'activity' in both the log and user tables combined. You'd get an
SQL error otherwise for having an ambiguous column reference.

=item *
Assumption is that the user enters the date in as a MySQL timestamp in the form. I got lazy as I was writing this
example. Also, the form would probably not look great, because the table is not formatted, nor does it have an
alignment on the page -- the report would be centered and the form left-justified. Making things pretty is left
as an exercise for the reader.

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
Robert Egert helped with design of the ReportWriter module with regards to rendering the results, and
indirectly suggested a simplified COLUMNS definition.

=back

=head1 COPYRIGHT

Copyright 2004, Shane Allen. All rights reserved.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut

__DATA__
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">
<html>
<head>
<title>[% PAGE_TITLE %]</title>
[% CSS %]
</head>
<body>
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
