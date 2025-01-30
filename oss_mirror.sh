#!/bin/bash

set -e -u

# Source is the <Repl> Repo you're syncing from.
source=""

# Target is the <target> repo that you're sync to.
targetFolder=""

# The latest commit synced already in OSS
cherrypick_start=""

sync_mode=""

help=""

while getopts "s:t:c:oph" opt; do
  case $opt in
    s) source="$OPTARG"
    ;;
    t) targetFolder="$OPTARG"
    ;;
    c) cherrypick_start="$OPTARG"
    ;;
    o) sync_mode="oss"
    ;;
    p) sync_mode="<repl>"
    ;;
    h) help="true"
  esac

  # Assume empty string if it's unset since we cannot reference to
  # an unset variabled due to "set -u".
  case ${OPTARG:-""} in
    -*) echo "Option $opt needs a valid argument. use -h to get help."
    exit 1
    ;;
  esac
done

green=`tput setaf 2`
red=`tput setaf 1`
reset=`tput sgr0`


tmpdir=tmp_sync

if [ "$source" == "" ] || [ "$targetFolder" == "" ] || [ "$cherrypick_start" == "" ] || [ "$sync_mode" == "" ]; then
   help="true";
fi

if [ "$help" == "true" ]; then
    echo "${green}sets up and syncs the <repl> and <target> repos."
    echo "${green}${0} -s <source_dir> -t <targetdir> -c <change_source_start> -o -p -h"
    echo "${green}[-s] The source repo directory to mirror"
    echo "${green}[-t] The target repo directory to mirror to"
    echo "${green}[-c] The last known change that was synced in the target - mirroring starts from here."
    echo "${green}[-o] sync mode is <Repl> -> OSS"
    echo "${green}[-p] sync mode is OSS -> <Repl> "
    exit 1;
fi

is_filter_repo_available=$(command -v git-filter-repo || true)
if [ "$is_filter_repo_available" == "" ]; then
   echo "${red}git-filter-repo is not installed. Please install it with 'sudo apt-get install git-filter-repo'${reset}"
   exit 1;
fi

if [ ! -d $source ]; then
   echo "${red} source directory ${source} does not exist ${reset}";
   exit 1;
fi

if [ ! -d $targetFolder ]; then
   echo "${red} targetFolder directory ${targetFolder} does not exist ${reset}";
   exit 1;
fi

syncHistoryFile="$(realpath -s $targetFolder)/sync-history.txt";
if [ ! -e $syncHistoryFile ]; then
    echo "${red} $syncHistoryFile file doesn't exist ${reset}";
    exit 1;
fi

function ValidateDirectoryIs<target>()
{
   local _folder=$1
   remoteDirOutput="$( cd -P $_folder && git remote -v | grep <target> || true )"
   if [ "$remoteDirOutput" == "" ]; then
      echo "Expecting directory $_folder to be <target>" >&2
      exit 1
   fi
}

function ValidateDirectoryIs<Repl>()
{
   local _folder=$1
   remoteDirOutput="$( cd -P $_folder && git remote -v | grep <repl> || true )"
   if [ "$remoteDirOutput" == "" ]; then
      echo "Expecting directory $_folder to be <repl>" >&2
      exit 1
   fi
}

startCommit=$(head -n 1 $syncHistoryFile)

# while IFS= read -r line; do
#     if [[ $line == START=* ]]; then
#         value="${line#START=}"  # Remove 'START=' prefix
#         startCommit=$value
#         echo "${green}Starting to port commits not ported from $startCommit to HEAD${reset}"
#     else
#         ported_commits["$line"]=1
#     fi
# done < "$syncHistoryFile"

if [ "$startCommit" == "" ]; then
    echo "${red}$syncHistoryFile doesn't contain a start commit"
    exit 1;
fi

patchTargetDir=""
revListCommand="git rev-list --reverse $startCommit..HEAD"

if [ "$sync_mode" == "oss" ]; then
    revListCommand="$revListCommand -- src/"
else
    patchTargetDir="src/"
fi


# if [ "$sync_mode" == "oss" ]; then
#    ValidateDirectoryIs<Repl> $source
#    ValidateDirectoryIs<target> $targetFolder
# else
#    ValidateDirectoryIs<target> $source
#    ValidateDirectoryIs<Repl> $targetFolder
# fi


echo "${green}Refreshing main for ${source}${reset}"

pushd $source
git checkout main
git pull

if ! git log --oneline $startCommit > /dev/null 2>&1; then
    echo "${red}Start commit: $startCommit doesn't exist on $source${reset}"
    exit 1
fi
# git branch -f $tempBranchName origin/main

commits_to_port=();
while IFS= read -r line; do
    commits_to_port+=("$line")
done < <(eval "$revListCommand") 


port_commit_message="[Automated sync]"

echo "${green}Mirroring history from ${source} to ${targetFolder}${reset}"

if [ "$sync_mode" == "oss" ]; then
    git filter-repo \
        --source "$source" \
        --target "$targetFolder" \
        --force \
        --refs "$tempBranchName" \
        --subdirectory-filter src
else
    git filter-repo \
        --source "$source" \
        --target "$targetFolder" \
        --force \
        --refs "$tempBranchName" \
        --prune-empty always \
        --path-rename :src/ \
        --preserve-commit-hashes
fi


mkdir -p $tmpdir
tmpdir=$(realpath -s $tmpdir)


for entry in "${commits_to_port[@]}"; do
    messageFile=$tmpdir/$entry-message.txt
    patchFile=$tmpdir/$entry.patch

    message=$(git show -s --format=%B $entry)

    if [[ "$message" == *"$port_commit_message"* ]]; then
        echo "Skipping: $entry because it is labeled as $port_commit_message"
        continue;
    fi

    echo $message > $messageFile
    echo "" >> $messageFile
    echo "$port_commit_message" >> $messageFile

    if [ "$sync_mode" == "oss" ]; then
        git format-patch --stdout --relative=src -1 $entry > $patchFile
    else
        git format-patch --stdout -1  $entry > $patchFile
    fi
done

popd

# targetBranchName=$(date +<target>push_%m_%d_%H_%M)
targetBranchName=$(date +<target>push_%m_%d_%H_%M)

echo "${green}Refreshing main for $targetFolder ${reset}"
pushd $targetFolder
git checkout main
git pull
git branch -f $targetBranchName origin/main
git checkout $targetBranchName


lastCommit=""

for file in $(ls -ltUc -- $tmpdir/*.patch | awk '{print $9}'); do
    commitToApply=$(basename "$file" .patch)
    echo "Applying $file"
    
    message=$(cat "$tmpdir/$commitToApply-message.txt");

    if git am --committer-date-is-author-date -3 --directory=$patchTargetDir $file; then
        git commit --amend --m "$message"
        rm -f $file
        rm -f $tmpdir/$commitToApply-message.txt
    else
        echo "${red}Failed to apply commit: $commitToApply${reset}".
        echo "Please fix merge conflicts"
        echo "Go to the $targetFolder and run: git status for more information."
        echo "${red}Once you fix merge conflicts, please run the following:${reset}"
        echo ""
        echo "git commit --amend --m \"$message\""
        echo ""
        rm -f $file
        rm -f $tmpdir/$commitToApply-message.txt
        
        while true; do
            read -p "Type 'yes' when you have fixed it to continue or 'abort' to cancel: " input
            if [[ "$input" == "yes" ]]; then
                break
            elif [[ "$input" == "abort" ]]; then
                echo "Aborting"
                rm -rf $tmpdir
                git am --abort
                popd
                exit 1;
            fi
            echo "Invalid input. Please type 'yes' to continue or 'abort' to cancel."
        done
        echo "Continuing..."
    fi

    lastCommit=$commitToApply
done

rm -rf $tmpdir

if [ "$lastCommit" != "" ]; then
    echo "${green}Updating $syncHistoryFile with last applied commit${reset}"
    echo "$lastCommit" > $syncHistoryFile
    git add .
    git commit -m "Update sync history" -m "" -m "$port_commit_message"
else
    echo "${red}No commits applied${reset}"
fi

popd


# echo "${green}Getting commit for cherrypick_start: $targetFolder $cherrypick_start ${reset}"

# # script can't find the last sync commit message on the target repo if the target repo is updated independently
# # find the last sync commit message at the target repo and adjust the command accordingly
# # following is for a case when the target repo is got a single commit after the last sync
# # last_commit_msg=`git log -2 --pretty=%B --oneline | tail -1 | awk '{ st = index($0," "); print substr($0, st +1 )}'`
# last_commit_msg=$(git log -1 $cherrypick_start --pretty=%B --oneline | awk '{ st = index($0," "); print substr($0, st +1 )}')

# if [ "$last_commit_msg" == "" ]; then
# echo "${red} unable to find $cherrypick_start in target ${reset}"
# exit 1
# fi

# git checkout $tempBranchName
# cherry_pick_from=`git log --grep="$last_commit_msg" --oneline | awk -F' ' '{ print $1}'`

# # target repo may have received other updates
# if [ ${#cherry_pick_from} -eq 0 ] ; then
#    echo "Unable to find commit from head of the main branch: Maybe since sync is too old"
#    exit 1
# fi

# echo "${green}Running cherry-pick from $cherry_pick_from to $tempBranchName ${reset}"
# git cherry-pick --keep-redundant-commits --allow-empty ..$tempBranchName
