package CATS::UI::Console;

use strict;
use warnings;

use Encode qw(decode_utf8);
use List::Util;

use CATS::ContestParticipate qw(get_registered_contestant);
use CATS::Countries;
use CATS::DB;
use CATS::Globals qw($cid $contest $is_jury $is_root $sid $t $uid $user);
use CATS::ListView;
use CATS::Messages qw(msg res_str);
use CATS::Output qw(auto_ext init_template url_f);
use CATS::Problem::Utils;
use CATS::Request;
use CATS::Settings qw($settings);
use CATS::Time;
use CATS::Utils qw(coalesce date_to_iso escape_xml url_function);
use CATS::Verdicts;
use CATS::Web qw(param url_param);

# This is called before init_template to display submitted question immediately.
sub send_question_to_jury {
    my ($question_text) = @_;

    $user->{is_participant} && defined $question_text && $question_text ne ''
        or return;
    length($question_text) <= 1000 or return res_str(1063);

    my ($previous_question_text) = $dbh->selectrow_array(q~
        SELECT question FROM questions
        WHERE account_id = ? ORDER BY submit_time DESC ROWS 1~, undef,
        $user->{ca_id});
    ($previous_question_text || '') ne $question_text or return msg(1061);

    my $s = $dbh->prepare(q~
        INSERT INTO questions(id, account_id, submit_time, question, received, clarified)
        VALUES (?, ?, CURRENT_TIMESTAMP, ?, 0, 0)~);
    $s->bind_param(1, new_id);
    $s->bind_param(2, $user->{ca_id});
    $s->bind_param(3, $question_text, { ora_type => 113 } );
    $s->execute;
    $s->finish;
    $dbh->commit;
    msg(1062);
}

sub get_settings {
    my ($lv) = @_;
    my $s = $lv->settings;
    $s->{i_value} = param('i_value') // $s->{i_value} // 1;
    $s->{i_unit} = param('i_unit') || $s->{i_unit} || 'hours';
    $s->{show_results} = param('show_results') // $s->{show_results} // 1;
    $s->{show_messages} = param('show_messages') // $s->{show_messages} // 0;
    $s->{show_contests} = param('show_contests') // $s->{show_contests} // 0;
    $s;
}

sub time_interval_days {
    my ($s) = @_;
    my ($v, $u) = @$s{qw(i_value i_unit)};
    my @text = split /\|/, res_str(1121);
    my $units = [
        { value => 'hours', k => 1 / 24 },
        { value => 'days', k => 1 },
        { value => 'months', k => 30 },
    ];
    map { $units->[$_]->{text} = $text[$_] } 0..$#$units;

    my $selected_unit = $units->[0];
    for (@$units) {
        if ($_->{value} eq $u) {
            $selected_unit = $_;
            last;
        }
    }
    $selected_unit->{selected} = 1;

    $t->param(
        i_values => [
            map { { value => $_, text => ($_ > 0 ? $_ : res_str(558)) } }
                (1..5, 10, 20, -1)
        ],
        i_units => $units
    );

    return $v > 0 ? $v * $selected_unit->{k} : 100000;
}

sub init_console_template {
    my ($template_name) = @_;
    my $se = param('se') || '';
    $se = "_$se" if $se;
    CATS::ListView->new(
        name => "console$se", array_name => 'console', template => $template_name);
}

sub console_content {
    my $selection = param('selection');

    my $lv = init_console_template(auto_ext('console_content'));

    retest_submissions($selection, param('by_reference')) if defined param('retest') and $selection;
    group_submissions($selection, param('by_reference')) if defined param('create_group') && $selection;

    my $s = get_settings($lv);

    if (grep defined param($_), qw(search filter visible)) {
        $s->{$_} = param($_) ? 1 : 0
            for qw(show_contests show_messages show_results);
    }

    $t->param($_ => $s->{$_}) for qw(show_contests show_messages show_results i_value);

    my $day_count = time_interval_days($s);
    my $dummy_account_block = q~
        CAST(NULL AS INTEGER) AS team_id,
        CAST(NULL AS VARCHAR(200)) AS team_name,
        CAST(NULL AS VARCHAR(30)) AS country,
        CAST(NULL AS VARCHAR(100)) AS last_ip,
        CAST(NULL AS INTEGER) AS caid
    ~;
    my $dummy_req_block = q~
        CAST(NULL AS INTEGER) AS request_state,
        CAST(NULL AS INTEGER) AS failed_test,
        CAST(NULL AS INTEGER) AS problem_id,
        CAST(NULL AS VARCHAR(200)) AS problem_title
    ~;
    my $no_de = 'CAST(NULL AS VARCHAR(200)) AS de';
    my $city_sql = $is_jury ?
        q~ || (CASE WHEN A.city IS NULL OR A.city = '' THEN '' ELSE ' (' || A.city || ')' END)~ : '';
    my @contest_date_types = qw(start freeze finish);
    my %console_select = (
        run => qq~
            1 AS rtype,
            R.submit_time AS rank,
            R.submit_time,
            R.id AS id,
            R.state AS request_state,
            R.failed_test AS failed_test,
            R.problem_id AS problem_id,
            P.title AS problem_title,
            (SELECT s.de_id FROM sources s WHERE s.req_id = R.id) AS de,
            R.points AS clarified,
            NULL AS question,
            NULL AS answer,
            CAST(R.tag AS BLOB) AS jury_message,
            A.id AS team_id,
            A.team_name$city_sql AS team_name,
            A.country AS country,
            COALESCE(E.ip, A.last_ip) AS last_ip,
            CA.id,
            R.contest_id
            FROM reqs R
            INNER JOIN problems P ON R.problem_id = P.id
            INNER JOIN accounts A ON R.account_id = A.id
            INNER JOIN contests C ON R.contest_id = C.id
            LEFT JOIN contest_accounts CA ON CA.account_id = A.id AND CA.contest_id = R.contest_id
            LEFT JOIN events E ON E.id = R.id
        ~,
        question => qq~
            2 AS rtype,
            Q.submit_time AS rank,
            Q.submit_time,
            Q.id AS id,
            $dummy_req_block,
            $no_de,
            Q.clarified AS clarified,
            Q.question AS question,
            Q.answer AS answer,
            NULL AS jury_message,
            A.id AS team_id,
            A.team_name AS team_name,
            A.country AS country,
            A.last_ip AS last_ip,
            CA.id,
            CA.contest_id~,
        message => qq~
            3 AS rtype,
            E.ts AS rank,
            E.ts AS submit_time,
            M.id AS id,
            $dummy_req_block,
            $no_de,
            CAST(NULL AS INTEGER) AS clarified,
            NULL AS question,
            NULL AS answer,
            M.text AS jury_message,
            A.id AS team_id,
            A.team_name AS team_name,
            A.country AS country,
            A.last_ip AS last_ip,
            CA.id,
            M.contest_id
            FROM messages M
            INNER JOIN events E ON E.id = M.id
            INNER JOIN accounts A ON E.account_id = A.id
            INNER JOIN contests C ON C.id = M.contest_id
            LEFT JOIN contest_accounts CA ON M.contest_id = CA.contest_id AND E.account_id = CA.account_id
        ~,
        broadcast => qq~
            4 AS rtype,
            E.ts AS rank,
            E.ts AS submit_time,
            M.id AS id,
            $dummy_req_block,
            $no_de,
            CAST(NULL AS INTEGER) AS clarified,
            NULL AS question,
            NULL AS answer,
            M.text AS jury_message,
            $dummy_account_block,
            M.contest_id
            FROM messages M
            INNER JOIN events E ON E.id = M.id
            LEFT JOIN contests C ON C.id = M.contest_id
        ~,
        (map { +"contest_$contest_date_types[$_]" => qq~
            5 AS rtype,
            C.$contest_date_types[$_]_date AS rank,
            C.$contest_date_types[$_]_date AS submit_time,
            C.id AS id,
            C.is_official AS request_state,
            $_ AS failed_test,
            CAST(NULL AS INTEGER) AS problem_id,
            C.title AS problem_title,
            $no_de,
            CAST(NULL AS INTEGER) AS clarified,
            NULL AS question,
            NULL AS answer,
            NULL AS jury_message,
            $dummy_account_block,
            C.id AS contest_id
            FROM contests C
        ~ } 0 .. $#contest_date_types),
    );

    my $runs_filter = $s->{show_results} ? '' : ' AND 1 = 0';
    my $user_filter = url_param('uf') || '';
    my @user_ids = grep /^\d+$/, split ',', $user_filter;
    my $events_filter = @user_ids ? 'AND (' . join(' OR ', map 'A.id = ?', @user_ids) . ')' : '';
    my @events_filter_params = @user_ids;

    my $submit_time_filter =
        '(R.submit_time BETWEEN C.start_date AND C.freeze_date OR CURRENT_TIMESTAMP > C.defreeze_date)';

    my $DEs = $uid ? $dbh->selectall_hashref(q~
        SELECT id, code, description FROM default_de~, 'id') : {};

    # Optimization: Only display problem codes from the currect contest to avoid another JOIN.
    my $problem_codes = !$contest->is_practice ? $dbh->selectall_hashref(q~
        SELECT problem_id, code FROM contest_problems WHERE contest_id = ?~, 'problem_id', undef, $cid) : {};

    $lv->define_db_searches([ qw(
        R.submit_time
        R.id
        R.state
        R.failed_test
        R.problem_id
        R.points
        R.judge_id
        R.elements_count
        P.title
        A.team_name
        A.city
        CA.is_jury
    ) ]);

    my $de_select = q~
        (SELECT %s FROM sources S INNER JOIN default_de DE ON DE.id = S.de_id WHERE S.req_id = R.id)~;

    $lv->define_db_searches({
        de_code => sprintf($de_select, 'DE.code'),
        de_name => sprintf($de_select, 'DE.description'),
        run_method => 'P.run_method',
        code => '(SELECT CP.code FROM contest_problems CP WHERE CP.contest_id = C.id AND CP.problem_id = P.id)',
        next => q~COALESCE((
            SELECT R1.id FROM reqs R1
            WHERE
                R1.contest_id = R.contest_id AND
                R1.problem_id = R.problem_id AND
                R1.account_id = R.account_id AND
                R1.id > R.id
            ROWS 1), 0)~,
        tag => q~COALESCE(R.tag, '')~,
        account_id => 'A.id',
        contest_id => 'C.id',
    });

    $lv->define_enums({
        state => $CATS::Verdicts::name_to_state,
        run_method => CATS::Problem::Utils::run_method_enum,
        contest_id => { this => $cid },
        account_id => { this => $uid },
    });

    my $search_cid = $lv->search_value('contest_id');
    my $broadcast = $s->{show_messages} ? qq~
            UNION
        SELECT
            $console_select{broadcast}
            WHERE E.ts > CURRENT_TIMESTAMP - $day_count AND M.broadcast = 1~ .
            ($is_root && !$search_cid ?
                '' : ' AND (M.contest_id IS NULL OR M.contest_id = ?)')
        : '';
    my @broadcast_param = !$s->{show_messages} ? () : !$is_root ? ($cid) : $search_cid ? ($search_cid) : () ;

    my $contest_dates = '';
    my @contest_params;
    if ($s->{show_contests}) {
        my %avoid_dups_cond = (
            start => '',
            freeze => ' AND C.freeze_date < C.finish_date AND C.freeze_date > C.start_date',
            finish => '');
        my $id_cond = $is_root && !$search_cid ? '' : ' AND C.id = ?';
        $contest_dates = join '', map qq~
                UNION
            SELECT
                $console_select{"contest_$_"}
                WHERE C.${_}_date > CURRENT_TIMESTAMP - $day_count AND
                    C.${_}_date < CURRENT_TIMESTAMP$avoid_dups_cond{$_}$id_cond~,
                    qw(start freeze finish);
        @contest_params = !$is_root ? ($cid) x 3 : $search_cid ? ($search_cid) x 3 : ();
    }

    my $searches_filter = $lv->maybe_where_cond;

    my $c;
    if ($is_jury) {
        my $jury_runs_filter = $is_root ? '' : ' AND C.id = ?';
        my $msg_filter = $is_root ? '' : ' AND CA.contest_id = ?';
        $msg_filter .= ' AND 1 = 0' unless $s->{show_messages};
        my @msg_params;
        if ($lv->searches_subset_of({ account_id => 1, team_name => 1, city => 1, contest_id => 1 })) {
            $msg_filter .= $searches_filter;
            @msg_params = $lv->where_params;
        }
        elsif ($search_cid) {
            $msg_filter .= ' AND C.id = ?';
            @msg_params = $search_cid;
        }
        my @cid = $is_root ? () : ($cid);
        $c = $dbh->prepare(qq~
            SELECT
                $console_select{run}
                WHERE R.submit_time > CURRENT_TIMESTAMP - $day_count
                $jury_runs_filter$events_filter$runs_filter$searches_filter
            UNION
            SELECT
                $console_select{question}
                FROM questions Q
                INNER JOIN contest_accounts CA ON Q.account_id = CA.id
                INNER JOIN accounts A ON CA.account_id = A.id
                INNER JOIN contests C ON C.id = CA.contest_id
                WHERE Q.submit_time > CURRENT_TIMESTAMP - $day_count
                $msg_filter
                $events_filter
            UNION
            SELECT
                $console_select{message}
                WHERE E.ts > CURRENT_TIMESTAMP - $day_count
                $msg_filter
                $events_filter
            $broadcast
            $contest_dates
            ORDER BY 2 DESC~);
        $c->execute(
            @cid, @events_filter_params, $lv->where_params,
            @cid, @msg_params, @events_filter_params,
            @cid, @msg_params, @events_filter_params,
            @broadcast_param,
            @contest_params,
        );
    }
    elsif ($user->{is_participant}) {
        $c = $dbh->prepare(qq~
            SELECT
                $console_select{run}
                WHERE (R.submit_time > CURRENT_TIMESTAMP - $day_count) AND
                    C.id = ? AND CA.is_hidden = 0 AND
                    (A.id = ? OR $submit_time_filter)
                $events_filter$runs_filter$searches_filter
            UNION
            SELECT
                $console_select{question}
                FROM questions Q
                INNER JOIN contest_accounts CA ON Q.account_id = CA.id
                INNER JOIN accounts A ON CA.account_id = A.id
                INNER JOIN contests C ON C.id = CA.contest_id
                WHERE Q.submit_time > CURRENT_TIMESTAMP - $day_count AND
                    CA.contest_id = ? AND A.id = ?
            UNION
            SELECT
                $console_select{message}
                WHERE E.ts > CURRENT_TIMESTAMP - $day_count AND M.contest_id = ? AND E.account_id = ?
            $broadcast
            $contest_dates
            ORDER BY 2 DESC~);
        $c->execute(
            $cid, $uid, @events_filter_params, $lv->where_params,
            $cid, $uid,
            $cid, $uid,
            @broadcast_param,
            @contest_params,
        );
    }
    else {
        $c = $dbh->prepare(qq~
            SELECT
                $console_select{run}
                WHERE R.submit_time > CURRENT_TIMESTAMP - $day_count AND
                    R.contest_id = ? AND CA.is_hidden = 0 AND
                    ($submit_time_filter)
                    $events_filter$runs_filter$searches_filter
            $broadcast
            $contest_dates
            ORDER BY 2 DESC~);
        $c->execute(
            $cid, @events_filter_params, $lv->where_params, @broadcast_param, @contest_params);
    }

    my $fetch_console_record = sub {
        my ($rtype, $rank, $submit_time, $id, $request_state, $failed_test,
            $problem_id, $problem_title, $de, $clarified, $question, $answer, $jury_message,
            $team_id, $team_name, $country_abbr, $last_ip, $caid, $contest_id
        ) = $_[0]->fetchrow_array
            or return ();

        $request_state = -1 unless defined $request_state;

        my ($country, $flag) = CATS::Countries::get_flag($country_abbr);

        # Security: During the contest, show teams only accepted/rejected
        # instead of specific results of other teams.
        my $hide_verdict =
            $contest->{time_since_defreeze} <= 0 && !$is_jury &&
            (!$user->{is_participant} || !$team_id || $team_id != $uid);
        my $true_short_state = $CATS::Verdicts::state_to_name->{$request_state} || '';
        my $short_state = $hide_verdict ? $CATS::Verdicts::hidden_verdicts->{$true_short_state} : $true_short_state;
        my $show_details = $is_jury || $uid && $team_id && $uid == $team_id;

        return (
            country => $country,
            flag => $flag,
            is_submit_result =>     $rtype == 1,
            is_question =>          $rtype == 2,
            is_message =>           $rtype == 3,
            is_broadcast =>         $rtype == 4,
            is_contest =>           $rtype == 5,
            ($rtype == 5 ? (contest_date_type => $contest_date_types[$failed_test]) : ()),
            is_official =>          $request_state,
            # Hack: re-use 'clarified' field since it is relevant for questions only.
            points =>               $clarified,
            clarified =>            $clarified,
            (($contest_id // 0) == $cid && $problem_id ? (code => $problem_codes->{$problem_id}->{code}) : ()),
            href_details =>         ($show_details ? url_f('run_details', rid => $id) : undef),
            href_source =>          ($show_details ? url_f('view_source', rid => $id) : undef),
            href_problems =>        url_function('problems', sid => $sid, cid => $id),
            ($is_jury && $user->privs->{moderate_messages} ? (
                href_delete_question => url_f('console', delete_question => $id),
                href_delete_message =>  url_f('console', delete_message => $id),
            ) : ()),
            href_answer_box =>
                $is_jury && (!$clarified || $user->privs->{moderate_messages}) ?
                url_f('answer_box', qid => $id) : undef,
            href_send_message_box =>
                ($is_jury && $caid ? url_f('send_message_box', caid => $caid) : undef),
            'time' =>               $submit_time,
            time_iso =>             date_to_iso($submit_time),
            problem_id =>           $problem_id,
            problem_title =>        $problem_title,
            de =>                   $de,
            request_state =>        $request_state,
            short_state =>          $short_state,
            failed_test =>          ($hide_verdict ? '' : $failed_test),
            question_text =>        decode_utf8($question),
            answer_text =>          decode_utf8($answer),
            message_text =>         decode_utf8($jury_message),
            team_id =>              $team_id,
            team_name =>            $team_name,
            CATS::IP::linkify_ip($last_ip),
            id      =>              $id,
            contest_id =>           $contest_id,
        );
    };

    $lv->attach(
        url_f('console'), $fetch_console_record, $c,
        { page_params => { se => param('se') || undef, uf => $user_filter || undef } });

    $c->finish;

    if ($user->{is_participant} && !$settings->{hide_envelopes}) {
        my $cond =
            "WHERE account_id = ? AND state >= $cats::request_processed " .
            'AND received = 0 AND contest_id = ?';
        my $envelope_ids = $dbh->selectcol_arrayref(qq~
            SELECT id FROM reqs $cond~, undef,
            $uid, $cid
        );
        $t->param(envelopes => [
            map { href_envelope => url_f('envelope', rid => $_) }, @$envelope_ids ]);
        $dbh->commit; # Minimize deadlock chance.
        $dbh->do(qq~
            UPDATE reqs SET received = 1 $cond~, undef,
            $uid, $cid);
        $dbh->commit;
    }

    $t->param(
        DEs => $DEs,
    );
}

sub select_all_reqs {
    $dbh->selectall_arrayref(qq~
        SELECT
            R.id AS id, R.submit_time, R.state, R.failed_test,
            R.submit_time - $CATS::Time::contest_start_offset_sql AS time_since_start,
            CP.code, P.title AS problem_title,
            A.id AS team_id, A.team_name, A.last_ip,
            CA.is_remote, CA.is_ooc
        FROM
            reqs R
            INNER JOIN problems P ON R.problem_id = P.id
            INNER JOIN contest_accounts CA ON CA.contest_id = R.contest_id AND CA.account_id = R.account_id
            INNER JOIN contests C ON R.contest_id = C.id
            INNER JOIN contest_problems CP ON R.contest_id = CP.contest_id AND CP.problem_id = R.problem_id
            INNER JOIN accounts A ON CA.account_id = A.id
            LEFT JOIN contest_sites CS ON CS.contest_id = C.id AND CS.site_id = CA.site_id
        WHERE
            R.contest_id = ? AND CA.is_hidden = 0 AND CA.is_virtual = 0 AND R.submit_time > C.start_date
        ORDER BY R.submit_time ASC~, { Slice => {} },
        $cid);
}

sub export_frame {
    $is_jury or return;
    # Legacy field, new consumers should use short_state.
    my %state_to_display = (
        $cats::st_wrong_answer => 'wrong_answer',
        $cats::st_presentation_error => 'presentation_error',
        $cats::st_time_limit_exceeded => 'time_limit_exceeded',
        $cats::st_memory_limit_exceeded => 'memory_limit_exceeded',
        $cats::st_memory_limit_exceeded => 'write_limit_exceeded',
        $cats::st_runtime_error => 'runtime_error',
        $cats::st_compilation_error => 'compilation_error',
        $cats::st_idleness_limit_exceeded => 'idleness_limit_exceeded',
        $cats::st_manually_rejected => 'manually_rejected',
        $cats::st_not_processed => 'not_processed',
        $cats::st_unhandled_error => 'unhandled_error',
        $cats::st_install_processing => 'install_processing',
        $cats::st_testing => 'testing',
        $cats::st_awaiting_verification => 'awaiting_verification',
        $cats::st_accepted => 'accepted',
        $cats::st_security_violation => 'security_violation',
        $cats::st_ignore_submit => 'ignore_submit',
    );
    init_template('console_export.xml.tt');
    my $reqs = select_all_reqs;
    for my $req (@$reqs) {
        $req->{submit_time} =~ s/\s+$//;
        $req->{short_state} = $CATS::Verdicts::state_to_name->{$req->{state}};
        $req->{state} = $state_to_display{$req->{state}};
        $req->{s} = join '', map "<$_>" . escape_xml($req->{$_}) . "</$_>",
            sort grep defined $req->{$_}, keys %$req;
    }
    $t->param(reqs => $reqs);
}

sub graphs_frame {
    $is_jury or return;
    init_template('console_graphs.html.tt');

    my $reqs = select_all_reqs;
    my $n2s = $CATS::Verdicts::name_to_state;
    my $used_verdicts = {};

    for my $r (@$reqs) {
        $r->{minutes} = int($r->{time_since_start} * 24 * 60 + 0.5);
        $r->{verdict} = $CATS::Verdicts::state_to_name->{$r->{state}};
        $used_verdicts->{$r->{verdict}} = 1;
    }
    $t->param(
        reqs => $reqs,
        codes => $contest->used_problem_codes,
        verdicts => [ sort{ $n2s->{$a} <=> $n2s->{$b} } keys %$used_verdicts ],
        submenu => [ { href => url_f('console'), item => res_str(510) } ],
    );
}

sub retest_submissions {
    $is_jury or return;
    my ($selection, $by_reference) = @_;
    my $count = 0;
    my @sanitized_runs = grep $_ ne '', split /\D+/, $selection;
    if ($by_reference) {
        $count = @{CATS::Request::clone(\@sanitized_runs, undef, $uid)};
    } else {
        for (@sanitized_runs) {
            CATS::Request::enforce_state($_, { state => $cats::st_not_processed, judge_id => undef })
                and ++$count;
        }
    }
    $dbh->commit;
    return $count;
}

sub group_submissions {
    $is_root or return;
    my ($selection, $by_reference) = @_;
    my $count = 0;
    my @sanitized_runs = grep $_ ne '', split /\D+/, $selection;
    CATS::Request::create_group(
        ($by_reference ? CATS::Request::clone(\@sanitized_runs, undef, $uid, { state => $cats::st_ignore_submit }) : \@sanitized_runs),
        $uid, { state => $cats::st_not_processed, judge_id => undef }) or return;
    $dbh->commit;
}

sub delete_question {
    my ($qid) = @_;
    $is_jury && $user->privs->{moderate_messages} or return;
    $dbh->do(q~
        DELETE FROM questions WHERE id = ?~, undef,
        $qid);
    $dbh->commit;
}

sub delete_message {
    my ($mid) = @_;
    $is_jury && $user->privs->{moderate_messages} or return;
    $dbh->do(q~
        DELETE FROM messages WHERE id = ?~, undef,
        $mid);
    $dbh->commit;
}

sub console_frame {
    my ($p) = @_;
    delete_question($p->{delete_question}) if $p->{delete_question};
    delete_message($p->{delete_message}) if $p->{delete_message};
    send_question_to_jury($p->{question_text}) if $p->{send_question};

    console_content;
    return if param('json');
    CATS::Time::prepare_server_time;
    my $lvparams = $t->{vars};
    my $cc = $t->output;
    my $user_filter = url_param('uf') || '';

    my $lv = init_console_template('console.html.tt');

    $t->param($_ => $lvparams->{$_}) for qw(
        i_units i_unit i_values i_value display_rows rows
        page pages search show_contests show_messages show_results
        href_lv_action href_next_pages href_prev_pages search_hints search_enums
    );
    $t->param(
        href_console_content =>
            url_f('console_content', noredir => 1, map { $_ => (url_param($_) || '') } qw(uf se page)),
        selection => scalar(param('selection')),
        href_my_events_only =>
            url_f('console', uf => ($uid || $user->{anonymous_id}), se => param('se') || undef),
        href_all_events => url_f('console', uf => 0, se => param('se') || undef),
        href_view_source => url_f('view_source'),
        href_run_details => url_f('run_details'),
        href_run_log => url_f('run_log'),
        href_diff => url_f('diff_runs'),
        title_suffix => res_str(510),
        initial_content => $cc,
        autoupdate => $lv->settings->{autoupdate} // 30,
        ajax_error_msg => res_str(1151),
        user_filter => $user_filter,
    );
    my %all_types = (show_contests => 1, show_messages => 1, show_results => 1);
    $t->param(submenu => [
        { href => url_f('console_export'), item => res_str(561) },
        { href => url_f('console_graphs'), item => res_str(563) },
        { href => url_f('console', search => '',
            ($is_root ? (i_value => 1) : ()), %all_types), item => res_str(558) },
        ($is_root ? (
            { href => url_f('console', search => 'contest_id=this',
                i_value=> -1, %all_types), item => res_str(585) },
        ) : ()),
    ]) if $is_jury;
}

sub content_frame { console_content }

1;
