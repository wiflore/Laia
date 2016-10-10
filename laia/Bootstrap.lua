-- Utility functions for bootstrapping.
--
-- Example, how to compute CER with bootstrapped confidence intervals.
--
-- edit_ops = {1, 0, 2, 4, 2, 1, 4, 2, 3, 0, 3, 2, 1, 4}
-- ref_length = {12, 11, 9, 18, 12, 17, 10, 13, 12, 9, 11, 5, 1, 20}
--
-- -- Obtain empirical CER
-- cer = table.reduce(edit_ops, operator.add, 0) /
--       table.reduce(ref_length, operator.add, 0)
--
-- -- Obtain CER differences between each Bootstrap CER and the empirical CER.
-- -- CER differences are sorted in increasing order.
-- bootstrap_samples = laia.bootstrap_sample(#edit_ops, 1000)
-- bootstrap_edit_ops = laia.bootstrap_data(edit_ops, bootstrap_samples)
-- bootstrap_ref_length = laia.bootstrap_data(ref_length, bootstrap_samples)
-- cer_diffs = {}
-- for s=1:#bootstrap_samples do
--   local s_cer = table.reduce(bootstrap_edit_ops[s], operator.add, 0) /
--                 table.reduce(bootstrap_ref_length[s], operator.add, 0)
--   table.insert(cer_diffs, s_cer - cer)
-- end
-- table.sort(cer_diffs)
-- -- Compute bootstrap confidence intervals for the population CER.
-- -- Watch that lower/upper bounds are obtained from 97.5%/2.5%, respectively!
-- cer_lower = cer - cer_diffs[math.ceil(0.975 * #cer_diffs)]
-- cer_upper = cer - cer_diffs[math.ceil(0.025 * #cer_diffs)]
-- print(('The sample CER is %.2f, with a 95%% confidence interval in [%.2f, %.2f]'):format(cer, cer_lower, cer_upper))


-- Create `num_samples' boostrap samples from a set of `num_data' original
-- data items, using Case Resampling.
--
-- Each bootstrap sample has `num_data' elements randomly selected from the
-- range [1..num_data], i.e. resampling with repetitions.
--
-- See https://en.wikipedia.org/wiki/Bootstrapping_(statistics)#Case_resampling
laia.bootstrap_sample = function(num_data, num_samples)
  local bootstrap_samples = {}
  for s=1,num_samples do
    table.insert(bootstrap_samples, {})
    for i=1,num_data do
      table.insert(bootstrap_samples[s], torch.random(num_data))
    end
  end
  return bootstrap_samples
end

-- Create a set of bootstrapped datasets from a table with the original data and
-- a table with the list of bootstrapping samples.
--
-- Each element in the list of boostrap_samples is a list with the elements of
-- the original dataset to be included in that particular bootstrap sample.
--
-- See https://en.wikipedia.org/wiki/Bootstrapping_(statistics)#Case_resampling
laia.bootstrap_data = function(data, bootstrap_samples)
  assert(data ~= nil and type(data) == 'table',
	 'laia.bootstrap_data expects an input "data" table')
  assert(bootstrap_samples ~= nil and (type(bootstrap_samples) == 'table' or
					 laia.isint(bootstrap_samples)),
	 'laia.bootstrap_data expects an input "bootstrap_samples" table ' ..
	   'or integer')
  if laia.isint(bootstrap_samples) then
    bootstrap_samples = laia.bootstrap_sample(#data, bootstrap_samples)
  end
  local bootstrap_data = {}
  for s=1,#bootstrap_samples do
    if #data ~= #bootstrap_samples[s] then
      laia.log.warn('The number of data items in the bootstrap sample %d ' ..
		      'should be equal to the number of original data items ' ..
		      '(expected = %d, actual = %d)',
		    s, #data, #bootstrap_samples[s])
    end
    table.insert(bootstrap_data, {})
    for _,i in ipairs(bootstrap_samples[s]) do
      table.insert(bootstrap_data[s], data[i])
    end
  end
  return bootstrap_data
end
