Here's the full workflow, start to finish:

1) Create a branch

git checkout main
git pull origin main
git checkout -b your-branch-name

2) Make commits to it

git add .
git commit -m "Describe what you changed"

(repeat add/commit as you make more changes)

3) Push the branch to GitHub

git push -u origin your-branch-name

(-u only needed the first push on that branch — after that just git push)

Then open a PR on GitHub from that branch into main.

4) After the PR is merged

git checkout main
git pull origin main

Optional cleanup once merged (deletes the now-unneeded branch):

git branch -d your-branch-name
git push origin --delete your-branch-name