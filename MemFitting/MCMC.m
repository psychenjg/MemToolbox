%MCMC Markov chain Monte Carlo with tuned proposals and alternative parameterization
%    [params,stored] = MCMC_Convergence(data, model)
%
% MCMC function that automatically detects convergence using the technique
% of Gelman and Rubin (1992)
% You can make this work as a normal MCMC function without any 
% convergence detection by passing it the following parameters:
% ... 'ConvergenceVariance', Inf, 'SamplesPerChain', 5000, ...
%---------------------------------------------------------------------

function stored = MCMC(data, model, varargin)
  % Extra arguments and parsing
  %  Verbosity = 0,  Print nothing
  %  Verbosity = 1,  Print description of chains & when convergence happens
  %  Verbosity = 2,  Print ratio of between/within chain variance for each
  %    variable on each iteration
  %  ConvergenceVariance = Ratio of between/within chain variance needed
  %    for each variable to count as convergence
  %  SamplePerChain - how many samples to collect after convergence
  %  attained
  args = struct('Verbosity', 1, 'ConvergenceVariance', 1.2, ...
    'SamplesPerChain', 5000); 
  args = parseargs(varargin, args);
  
  % Ensure there is a model.prior, model.logpdf and model.pdf
  model = EnsureAllModelMethods(model);
  
  % How many chains to run?
  numChains = size(model.start,1);
  if numChains < 2
    error('MemToolbox:MCMC_Convergence:TooFewChains', ...
      ['MCMC_Convergence requires at least 2 chains to detect convergence. ' ...
      'Please pass a model with multiple rows in model.start().']);
  end
  
  % Setup initial values for all chains
  for c=1:numChains
    startInfo(c).numMonte = 2000;
    startInfo(c).cur = model.start(c,:);
    coMatrix = eye(length(model.movestd));
    coMatrix(coMatrix==1) = model.movestd;
    startInfo(c).burnCovariance = coMatrix;
    startInfo(c).curLike = 0;
    startInfo(c).acceptance = 0;
  end
  
  if args.Verbosity>=1
      fprintf('\n   Running %d chains...\n', numChains);
  end
  
  % Run chains until convergence detected
  converged = false;
  count = 0;
  while ~converged
    if count>0
      converged = IsConverged(chainStored, args.ConvergenceVariance, args.Verbosity);
    end
    parfor c=1:numChains
      % Run chain
      [chainStored(c), startInfo(c)] = ....
        MCMC_Chain(data, model, startInfo(c), args.Verbosity);
      
      % Learn about covariance
      startInfo(c).burnCovariance = startInfo(c).burnCovariance .* 0.75 + ...
        cov(chainStored(c).vals(:, :)) .* 0.25;
      
      % Increase acceptance rate
      if startInfo(c).acceptance < 0.15
        startInfo(c).burnCovariance = startInfo(c).burnCovariance ./ 3;
      end
    end
    count = count+1;
    if ~converged && args.Verbosity
      fprintf('   ... not yet converged (%d)\n', count*startInfo(1).numMonte);
    end
  end
  if args.Verbosity
      fprintf('   ... chains converged after %d samples!\n', count*startInfo(1).numMonte);
      fprintf('   ... collecting %d samples from converged distribution\n', args.SamplesPerChain);
  end
  
  % Collect 5000 samples from converged chains
  parfor c=1:numChains
    startInfo(c).numMonte = args.SamplesPerChain;
    [chainStored(c), startInfo(c)] = ....
        MCMC_Chain(data, model, startInfo(c), args.Verbosity);
  end
  
  % Combine values across chains
  stored.vals = [chainStored(1).vals];
  stored.like = [chainStored(1).like];
  stored.chain = ones(size(chainStored(1).like));
  for c=2:numChains
    stored.vals = [stored.vals; chainStored(c).vals];
    stored.like = [stored.like; chainStored(c).like];
    stored.chain = [stored.chain; ones(size(chainStored(c).like)).*c];
  end
end

%---------------------------------------------------------------------
function [stored, startInfo] = MCMC_Chain(data, model, startInfo, verbosity)
  
  % Parameters
  probabilityOfBigMove = 0.1; % probability of taking a big jump
  sizeFactorOfBigMove = 5; % a big move is bigMoveSize times bigger than normal
  
  % Set initial state
  asCell = num2cell(startInfo.cur);
  startInfo.curLike = model.logpdf(data, asCell{:}) + ...
    sum(log(model.prior(startInfo.cur)));
  
  % Initialize storage of param vals
  stored.vals = zeros(startInfo.numMonte, length(startInfo.cur));
  stored.like = zeros(startInfo.numMonte, 1);
  
  % Track acceptance
  acceptance = zeros(startInfo.numMonte,1);
  
  % Do MCMC
  for m=1:startInfo.numMonte
    % Pick move
    % - Proposal distribution here is implicitly a mvnormal that is
    % renormalized to be truncated by the edges of the legal parameter
    % values
    tryAgain = 1;
    while tryAgain == 1
      % Propose move
      movement = mvnrnd(zeros(1, length(startInfo.cur)), startInfo.burnCovariance);
      
      % Propose move
      if rand > probabilityOfBigMove
        new = startInfo.cur + movement;
      else
        new = startInfo.cur + sizeFactorOfBigMove.*movement;
      end
      
      % If any parameter is out of bounds, regenerate proposal
      tryAgain = any(new<model.lowerbound) || any(new>model.upperbound);
    end
    
    % Calc likelihood of new position
    if any(new<model.lowerbound) || any(new>model.upperbound)
      like = -Inf;
    else
      asCell = num2cell(new);
      like = model.logpdf(data, asCell{:}) + ...
        sum(log(model.prior(new)));
    end
    
    % Accept with probability proportional to likelihood ratio
    if rand < exp(like - startInfo.curLike)
      startInfo.cur = new;
      startInfo.curLike = like;
      acceptance(m) = 1;
    end
    
    % Store trace of startInfo.current position
    stored.vals(m, :) = startInfo.cur;
    stored.like(m) = startInfo.curLike;
  end
  
  startInfo.acceptance = mean(acceptance);
  if verbosity > 2
    fprintf('    MCMC chain acceptance rate: %0.2f\n', mean(acceptance));
  end
end


%---------------------------------------------------------------------
function b = IsConverged(stored, convergenceVariance, verbosity)
  nChains = length(stored);
  numPerChain = size(stored(1).vals,1);
  nParams = size(stored(1).vals,2);
  
  globalMeans = zeros(1,nParams);
  for c=1:nChains
    globalMeans = globalMeans + mean(stored(c).vals);
  end
  globalMeans = globalMeans ./ nChains;
  
  for v = 1:nParams
    for c=1:nChains
      vals = stored(c).vals(:, v);
      w(c) = var(vals);
      b(c) = (mean(vals)-globalMeans(v)).^2;
    end
    W = mean(w);
    B = (numPerChain/(nChains-1)) * sum(b);
    Sp = (numPerChain-1)/(numPerChain) * W + (1/numPerChain) * B;
    r(v) = sqrt(Sp/W);
  end
  if verbosity > 2
    fprintf('%0.1f ', r);
    fprintf('\n');
  end
  b = all(r<convergenceVariance | isnan(r));
end
