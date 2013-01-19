-- BGV
UPDATE issue
SET discussion_time = (SELECT next_time FROM auto_freeze WHERE id = 3) - '7 days'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id)
WHERE (SELECT next_time FROM auto_freeze WHERE id = 3) IS NOT NULL
AND (SELECT next_time FROM auto_freeze WHERE id = 3) > NOW()
AND (state = 'discussion' OR state = 'verification' OR state = 'voting')
AND (SELECT unit_id FROM area WHERE id = area_id) = 1
AND (SELECT name FROM policy WHERE id = policy_id) LIKE '%zur Mitgliederversammlung%'
AND discussion_time != (SELECT next_time FROM auto_freeze WHERE id = 3) - '7 days'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id)
AND (SELECT next_time FROM auto_freeze WHERE id = 3) - '7 days'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id) > '-00:10:00';

-- BGF
UPDATE issue
SET discussion_time = (SELECT next_time FROM auto_freeze WHERE id = 2) - '30 mins'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id)
WHERE (SELECT next_time FROM auto_freeze WHERE id = 2) IS NOT NULL
AND (SELECT next_time FROM auto_freeze WHERE id = 2) > NOW()
AND (state = 'discussion' OR state = 'verification' OR state = 'voting')
AND area_id = 6
AND policy_id = 41
AND discussion_time != (SELECT next_time FROM auto_freeze WHERE id = 2) - '30 mins'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id)
AND (SELECT next_time FROM auto_freeze WHERE id = 2) - '30 mins'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id) > '-00:05:00';

-- BV
UPDATE issue
SET discussion_time = (SELECT next_time FROM auto_freeze WHERE id = 1) - '30 mins'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id)
WHERE (SELECT next_time FROM auto_freeze WHERE id = 1) IS NOT NULL
AND (SELECT next_time FROM auto_freeze WHERE id = 1) > NOW()
AND (state = 'discussion' OR state = 'verification' OR state = 'voting')
AND area_id = 6
AND policy_id = 40
AND discussion_time != (SELECT next_time FROM auto_freeze WHERE id = 1) - '30 mins'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id)
AND (SELECT next_time FROM auto_freeze WHERE id = 1) - '30 mins'::interval - accepted - (SELECT CASE WHEN state = 'discussion' THEN verification_time + voting_time WHEN state = 'verification' THEN voting_time ELSE '00:00:00' END FROM policy WHERE id = policy_id) > '-00:05:00';

