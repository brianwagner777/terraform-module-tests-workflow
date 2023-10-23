#!/bin/bash

export MSYS_NO_PATHCONV=1

RED='\033[0;31m'
GREEN='\033[0;32m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

function count_pass_fail {
  exitcode=$1
  if [ $exitcode -eq 0 ] ; then
    echo -e "[${GREEN}pass${NC}]"
    let "num_pass+=1"
  else 
    echo -e "[${RED}fail${NC}]"
    let "num_fail+=1"
  fi
  let "num_total+=1"
}

function count_skip {
  let "num_skip+=1"
  echo -e "[${GRAY}skip${NC}]"
}

function dump_output_on_fail_or_request {
  exitcode=$1
  output_file=$2

  if [ \( $exitcode -ne 0 \) -o \( $show_output -ne 0 \) ] ; then
    echo -e '\n--- failure output ---'
    cat $output_file
    echo -e '\n--- end failure output ---'
  fi
}

function delete_rg_resources {
  rg_name=$1

  num_tries=0
  max_tries=5
  num_resources=1 # fake value so the loop always runs at least once

  # limit max number of tries while blanket destroying resources
  while [ \( $num_resources -gt 0 \) -a \( $num_tries -lt $max_tries \) ] ; do
    num_tries=$(expr $num_tries + 1)

    # list the ID of each resource in the resource group, except when the resource is tagged with "prevent_destroy" or is a resource with spaces in the ID
    resource_ids="$(az resource list -g $rg_name --query '[?tags.prevent_destroy==null].id' -o tsv | grep -v ' ')"
    num_resources=$(echo "$resource_ids" | wc -l)

    # shows as one line if empty
    if [ -z "$resource_ids" ] ; then
      num_resources=0
    fi
    
    # deletion of remaining resources may fail if there are dependencies
    if [ $num_resources -gt 0 ] ; then
      echo "Deleting $num_resources resource(s) - try #$num_tries ($rg_name)..."
      
      # always run last try with --verbose
      if [ $num_tries -lt $max_tries ] ; then
        # 'delete' stops on first resource that can't be deleted, creating possible dependency issue 
        for resource_id in $resource_ids ; do 
          az resource delete --ids $resource_id > /dev/null || echo ""
        done
      else
        echo "Adding --verbose for last try."
        set -x # echo input and output
        az resource delete --ids $resource_ids --verbose || echo ""
        set +x # disable trace
      fi
    fi
  done

  if [ $num_resources -gt 0 ] ; then
    echo "WARNING: Unable to delete $num_resources resource(s) in $rg_name - exceeded $max_tries max tries."
  fi
}

skip_destroy=1
show_output=1
name_pattern='*'
base_dir="examples"  # directory containing all test case directories
failure_exit_code=1
resource_group_name=""

while [ $# -gt 0 ] ; do
  case $1 in
  --base-dir)
     base_dir="$2" ; shift
     ;;
  --skip-destroy)
     skip_destroy=0
     echo "WARNING: destroy will be skipped for all tests."
     echo "         To clean up resources, re-run without '--skip-destroy'"
     ;;
  --name-pattern)
     name_pattern="$2" ; shift
     echo "Only tests matching $name_pattern will be run."
     ;;
  --usage)
     usage ; exit 0
     ;;
  --suppress-fail)
     failure_exit_code=0
     ;;
  --resource-group-name)
     resource_group_name="$2" ; shift
     echo "Flagging resource group '$resource_group_name' for cleanup after each test."
     ;;
  --show-output)
     show_output=0
     echo "All output will be shown."
     ;;
  *)
     echo "unrecognized arg '$1'"
     usage ; exit 1
     ;;
  esac

  shift
done

# test counts
num_fail=0
num_pass=0
num_skip=0
num_total=0

# check to make sure the directory exists
[ -d "$base_dir" ] || ( echo "$base_dir does not exist, exiting" && exit 1 )

# run each test separately
for testdir in $base_dir/$name_pattern ; do

  # each test must be in its own directory
  if [ ! -d "$testdir" ] ; then
    echo "Skipping non-dir $testdir ..."
    continue
  fi
  testcase="$(basename $testdir)"

  # init modules
  printf "$testcase : init => "
  init_out=$base_dir/$testcase.init.out
  terraform -chdir="$testdir" init -no-color >$init_out 2>&1
  init_exit=$?
  count_pass_fail $init_exit
  dump_output_on_fail_or_request $init_exit $init_out

  # apply changes
  printf "$testcase : apply => "
  apply_out=$base_dir/$testcase.apply.out
  terraform -chdir="$testdir" apply -no-color -auto-approve >$apply_out 2>&1
  apply_exit=$?
  count_pass_fail $apply_exit
  dump_output_on_fail_or_request $apply_exit $apply_out

  # call optional check-apply.sh in the testcase dir, if it exists
  printf "$testcase : check-apply.sh => "
  if [ -f "$testdir/check-apply.sh" ] ; then
    check_apply_out=$base_dir/$testcase.check-apply.out
    bash "$testdir/check-apply.sh" >$check_apply_out 2>&1
    check_apply_exit=$?
    count_pass_fail $check_apply_exit
    dump_output_on_fail_or_request $check_apply_exit $check_apply_out
  else 
    count_skip
  fi
 
  # destroy infra for cleanup
  printf "$testcase : destroy => "
  if [ $skip_destroy -ne 0 ] ; then
    destroy_out=$base_dir/$testcase.destroy.out
    terraform -chdir="$testdir" destroy -no-color -auto-approve >$destroy_out 2>&1
    destroy_exit=$?
    count_pass_fail $destroy_exit
    dump_output_on_fail_or_request $destroy_exit $destroy_out

    # clean up resource group if specified and destroy is not skipped
    if [ -n "$resource_group_name" ] ; then
      delete_rg_resources "$resource_group_name"
    fi

    # clean up state as it takes up a lot of space
    if [ $destroy_exit -eq 0 ] ; then
      printf "$testcase : (delete .terraform and terraform.state*) => " 
      rm -Rf "$testdir/.terraform" ; rm -f "$testdir/terraform.state" "$testdir/terraform.tfstate.backup" "$testdir/terraform.lock.hcl"
      echo -e "[${GRAY}done${NO_COLOR}]"
    fi
  else
    count_skip
  fi
done

echo "Summary:
  Total: $num_total
  Pass:  $num_pass
  Fail:  $num_fail
  Skip:  $num_skip"

# exit with non-zero code if at least one test failed, can be suppressed if ther are more actions to take
if [ "$num_fail" -gt 0 ] ; then
  exit $failure_exit_code
fi
