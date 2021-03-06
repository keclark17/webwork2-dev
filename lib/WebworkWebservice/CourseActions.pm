#!/usr/local/bin/perl -w 
use strict;
use warnings;

# Course manipulation functions for webwork webservices

package WebworkWebservice::CourseActions;

use WebworkWebservice;

use base qw(WebworkWebservice); 
use WeBWorK::DB;
use WeBWorK::DB::Utils qw(initializeUserProblem);
use WeBWorK::Utils qw(runtime_use cryptPassword);
use WeBWorK::Utils::CourseManagement qw(addCourse);
use WeBWorK::Debug;
use MIME::Base64 qw( encode_base64 decode_base64);

use Time::HiRes qw/gettimeofday/; # for log timestamp
use Date::Format; # for log timestamp

sub create {
	my ($self, $params) = @_;
	my $newcourse = $params->{'name'};
	# note this ce is different from $self->{ce}!
	my $ce = WeBWorK::CourseEnvironment->new({
			webwork_dir => $self->{ce}->{webwork_dir},
			courseName => $newcourse
		});
	my $db = $self->{db};
	my $authz = $self->{authz};
	my $out = {};

	debug("Webservices course creation request.");
	# make sure course actions are enabled
	if (!$ce->{webservices}{enableCourseActions}) {
		debug("Course actions disabled by configuration.");
		$out->{status} = "failure";
		$out->{message} = "Course actions disabled by configuration.";
		return $out
	}
	# only users from the admin course with appropriate permissions allowed
	if (!($self->{ce}->{courseName} eq 'admin')) {
		debug("Course creation attempt when not logged into admin course.");
		$out->{status} = "failure";
		$out->{message} = "Course creation allowed only for admin course users.";
		return $out
	}
	# prof check is actually done when initiating session, this is just in case
	if (!$self->{authz}->hasPermissions($params->{'userID'}, 
			'create_and_delete_courses')) {
		debug("Course creation attempt with insufficient permission level.");
		$out->{status} = "failure";
		$out->{message} = "Insufficient permission level.";
		return $out
	}
	
	# declare params
	my @professors = ();
	my $dbLayout = $ce->{dbLayoutName};
	my %courseOptions = ( dbLayoutName => $dbLayout );
	my %dbOptions;
	my @users;
	my %optional_arguments;

	my $userClass = $ce->{dbLayouts}->{$dbLayout}->{user}->{record};
	my $passwordClass = $ce->{dbLayouts}->{$dbLayout}->{password}->{record};
	my $permissionClass = $ce->{dbLayouts}->{$dbLayout}->{permission}->{record};

	# copy instructors from admin course
	# modified from do_add_course in WeBWorK::ContentGenerator::CourseAdmin
	foreach my $userID ($db->listUsers) {
		my $User            = $db->getUser($userID);
		my $Password        = $db->getPassword($userID);
		my $PermissionLevel = $db->getPermissionLevel($userID);
		push @users, [ $User, $Password, $PermissionLevel ] 
			if $authz->hasPermissions($userID,"create_and_delete_courses");  
	}

	# all data prepped, try to actually add the course
	eval {
		addCourse(
			courseID => $newcourse,
			ce => $ce,
			courseOptions => \%courseOptions,
			dbOptions => \%dbOptions,
			users => \@users,
			%optional_arguments,
		);
		addLog($ce, "New course created: " . $newcourse);
		$out->{status} = "success";
	} or do {
		$out->{status} = "failure";
		$out->{message} = $@;
	};
	
	return $out;
}

sub listUsers {
    my ($self, $params) = @_;
    my $out = {};
    my $db = $self->{db};
    my $ce = $self->{ce};

    # make sure course actions are enabled
    #if (!$ce->{webservices}{enableCourseActions}) {
    #	$out->{status} = "failure";
    #	$out->{message} = "Course actions disabled by configuration.";
    #	return $out
    #}

    my @tempArray = $db->listUsers;
    my @userInfo = $db->getUsers(@tempArray);

    #%permissionsHash = reverse %permissionsHash;
    #for(@userInfo){
    #    @userInfo[i]->{'permission'} = $db->getPermissionLevel(@userInfo[i]->{'user_id'});
    #}
    my %permissionsHash = reverse %{$ce->{userRoles}};
    foreach my $u (@userInfo)
    {
        my $PermissionLevel = $db->getPermissionLevel($u->{'user_id'});
        $u->{'permission'}{'value'} = $PermissionLevel->{'permission'};
        $u->{'permission'}{'name'} = $permissionsHash{$PermissionLevel->{'permission'}};
    }

    #my %permissionsHash = $ce->{userRoles};
    #
    #push(@userInfo, %permissionsHash);

    #foreach $user (@userInfo){
    #    $user->{permission}
    #}

    $out->{ra_out} = \@userInfo;
    $out->{text} = encode_base64("Users for course: ".$self->{courseName});
    return $out;
}

sub addUser {
	my ($self, $params) = @_;
	my $out = {};
	my $db = $self->{db};
	my $ce = $self->{ce};
	debug("Webservices add user request.");

	# make sure course actions are enabled
	#if (!$ce->{webservices}{enableCourseActions}) {
	#	$out->{status} = "failure";
	#	$out->{message} = "Course actions disabled by configuration.";
	#	return $out
	#}

	# Two scenarios
	# 1. New user
	# 2. Dropped user deciding to re-enrol

	my $olduser = $db->getUser($params->{id});
	my $id = $params->{'id'};
	my $permission; # stores user's permission level
	if ($olduser) { 
		# a dropped user decided to re-enrol
		my $enrolled = $self->{ce}->{statuses}->{Enrolled}->{abbrevs}->[0];
		$olduser->status($enrolled);
		$db->putUser($olduser);
		addLog($ce, "User ". $id . " re-enrolled in " . 
			$ce->{courseName});
		$out->{status} = 'success';
		$permission = $db->getPermissionLevel($id);
	}
	else {
		# a new user showed up
		my $ce = $self->{ce};
		
		# student record
		my $enrolled = $ce->{statuses}->{Enrolled}->{abbrevs}->[0];
		my $new_student = $db->{user}->{record}->new();
		$new_student->user_id($id);
		$new_student->first_name($params->{'firstname'});
		$new_student->last_name($params->{'lastname'});
		$new_student->status($enrolled);
		$new_student->student_id($params->{'studentid'});
		$new_student->email_address($params->{'email'});
		
		# password record
		my $cryptedpassword = "";
		if ($params->{'userpassword'}) {
			$cryptedpassword = cryptPassword($params->{'userpassword'});
		}
		elsif ($new_student->student_id()) {
			$cryptedpassword = cryptPassword($new_student->student_id());
		}
		my $password = $db->newPassword(user_id => $id);
		$password->password($cryptedpassword);
		
		# permission record
		$permission = $params->{'permission'};
		if (defined($ce->{userRoles}{$permission})) {
			$permission = $db->newPermissionLevel(
				user_id => $id, 
				permission => $ce->{userRoles}{$permission});
		}
		else {
			$permission = $db->newPermissionLevel(user_id => $id, 
				permission => $ce->{userRoles}{student});
		}

		# commit changes to db
		$out->{status} = 'success';
		eval{ $db->addUser($new_student); };
		if ($@) {
			$out->{status} = 'failure';
			$out->{message} = "Add user for $id failed!\n";
		}
		eval { $db->addPassword($password); };
		if ($@) {
			$out->{status} = 'failure';
			$out->{message} = "Add password for $id failed!\n";
		}
		eval { $db->addPermissionLevel($permission); };
		if ($@) {
			$out->{status} = 'failure';
			$out->{message} = "Add permission for $id failed!\n";
		}

		addLog($ce, "User ". $id . " newly added in " . 
			$ce->{courseName});
	}

	# only students are assigned homework
	if ($ce->{webservices}{courseActionsAssignHomework} &&
		$permission->{permission} == $ce->{userRoles}{student}) {
		debug("Assigning homework.");
		my $ret = assignVisibleSets($db, $id);
		if ($ret) {
			$out->{status} = 'failure';
			$out->{message} = "User created but unable to assign sets. $ret";
		}
	}

	return $out;
}

sub dropUser {
	my ($self, $params) = @_;
	my $db = $self->{db};
	my $ce = $self->{ce};
	my $out = {};
	debug("Webservices drop user request.");

	# make sure course actions are enabled
	if (!$ce->{webservices}{enableCourseActions}) {
		$out->{status} = "failure";
		$out->{message} = "Course actions disabled by configuration.";
		return $out
	}

	# Mark user as dropped
	my $drop = $self->{ce}->{statuses}->{Drop}->{abbrevs}->[0];
	my $person = $db->getUser($params->{'id'});
	if ($person) {
		$person->status($drop);
		$db->putUser($person);
		addLog($ce, "User ". $person->user_id() . " dropped from " . 
			$ce->{courseName});
		$out->{status} = 'success';
	}
	else {
		$out->{status} = 'failure';
		$out->{message} = 'Could not find user';
	}

	return $out;
}


sub editUser {
	my ($self, $params) = @_;
    my $db = $self->{db};
    my $ce = $self->{ce};
    my $out = {};
    debug("Webservices edit user request.");

    # make sure course actions are enabled
    #if (!$ce->{webservices}{enableCourseActions}) {
    #	$out->{status} = "failure";
    #	$out->{message} = "Course actions disabled by configuration.";
    #	return $out
    #}

	my $User = $db->getUser($params->{'id'}); # checked
    die ("record for visible user [_1] not found" . $params->{'id'}) unless $User;
    my $PermissionLevel = $db->getPermissionLevel($params->{'id'}); # checked
    die "permissions for [_1] not defined". $params->{'id'} unless defined $PermissionLevel;
    foreach my $field ($User->NONKEYFIELDS()) {
    	my $param = "${field}";
    	if (defined $params->{$param}) {
    		$User->$field($params->{$param});
    	}
    }
    foreach my $field ($PermissionLevel->NONKEYFIELDS()) {
    	my $param = "${field}";
    	if (defined $params->{$param}) {
   	    	$PermissionLevel->$field($params->{$param});
    	}
    }

    $db->putUser($User);
    $db->putPermissionLevel($PermissionLevel);
    $User = $db->getUser($params->{'id'}); # checked

    my %permissionsHash = reverse %{$ce->{userRoles}};
    $PermissionLevel = $db->getPermissionLevel($User->{'user_id'});
    $User->{'permission'}{'value'} = $PermissionLevel->{'permission'};
    $User->{'permission'}{'name'} = $permissionsHash{$PermissionLevel->{'permission'}};

    $out->{ra_out} = $User;
    $out->{text} = encode_base64("Changes saved");

	return $out;
}

sub changeUserPassword {

	my ($self, $params) = @_;
    my $db = $self->{db};
    my $ce = $self->{ce};
    my $out = {};

    # make sure course actions are enabled
        if (!$ce->{webservices}{enableCourseActions}) {
        	$out->{status} = "failure";
        	$out->{message} = "Course actions disabled by configuration.";
        	return $out
        }

    my $User = $db->getUser($params->{'id'}); # checked
	die ("record for visible user [_1] not found". $params->{'id'}) unless $User;
	my $param = "new_password";
	if ((defined $params->{$param}->[0]) and ($params->{$param}->[0])) {
		my $newP = $params->{$param}->[0];
		my $Password = eval {$db->getPassword($User->user_id)}; # checked
		my 	$cryptPassword = cryptPassword($newP);
		$Password->password(cryptPassword($newP));
		eval { $db->putPassword($Password) };
	}

	$self->{passwordMode} = 0;
    $out->{message} = "New passwords saved";
	return $out;
}

sub addLog {
	my ($ce, $msg) = @_;
	if (!$ce->{webservices}{enableCourseActionsLog}) {
		return;
	}
	my ($sec, $msec) = gettimeofday;
	my $date = time2str("%a %b %d %H:%M:%S.$msec %Y", $sec);

	$msg = "[$date] $msg\n";

	my $logfile = $ce->{webservices}{courseActionsLogfile};
	if (open my $f, ">>", $logfile) {
		print $f $msg;
		close $f;
	}
	else {
		debug("Error, unable to open student updates log file '$logfile' in".
			"append mode: $!");
	}
	return;
}

sub assignVisibleSets {
	my ($db, $userID) = @_;
	my @globalSetIDs = $db->listGlobalSets;
	my @GlobalSets = $db->getGlobalSets(@globalSetIDs);

	my $i = -1;
	foreach my $GlobalSet (@GlobalSets) {
		$i++;
		if (not defined $GlobalSet) {
			debug("Record not found for global set $globalSetIDs[$i]");
			next;
		} 
		if (!$GlobalSet->visible) {
			next;
		}

		# assign set to user
		my $setID = $GlobalSet->set_id;
		my $UserSet = $db->newUserSet;
		$UserSet->user_id($userID);
		$UserSet->set_id($setID);
		my @results;
		my $set_assigned = 0;
		eval { $db->addUserSet($UserSet) }; 
		if ( $@ && !($@ =~ m/user set exists/)) {
			return "Failed to assign set to user $userID";
		}

		# assign problem
		my @GlobalProblems = grep { defined $_ } $db->getAllGlobalProblems($setID);
		foreach my $GlobalProblem (@GlobalProblems) {
			my $seed = int( rand( 2423) ) + 36;
			my $UserProblem = $db->newUserProblem;
			$UserProblem->user_id($userID);
			$UserProblem->set_id($GlobalProblem->set_id);
			$UserProblem->problem_id($GlobalProblem->problem_id);
			initializeUserProblem($UserProblem, $seed);
			eval { $db->addUserProblem($UserProblem) };
			if ($@ && !($@ =~ m/user problem exists/)) {
				return "Failed to assign problems to user $userID";
			}
		}
	}

	return 0;
}

1;
