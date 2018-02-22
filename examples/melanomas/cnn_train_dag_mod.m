function [net,stats] = cnn_train_dag(net, net_seg, imdb, getBatch, varargin)
%CNN_TRAIN_DAG Demonstrates training a CNN using the DagNN wrapper
%    CNN_TRAIN_DAG() is similar to CNN_TRAIN(), but works with
%    the DagNN wrapper instead of the SimpleNN wrapper.

% Copyright (C) 2014-16 Andrea Vedaldi.
% All rights reserved.
%
% This file is part of the VLFeat library and is made available under
% the terms of the BSD license (see the COPYING file).

opts.expDir = fullfile('data','exp') ;
opts.continue = true ;
opts.batchSize = 256 ;
opts.numSubBatches = 1 ;
opts.train = [] ;
opts.val = [] ;
opts.gpus = [] ;
opts.prefetch = false ;
opts.numEpochs = 300 ;
opts.learningRate = 0.001 ;
opts.weightDecay = 0.0005 ;
opts.momentum = 0.9 ;
opts.saveMomentum = true ;
opts.nesterovUpdate = false ;
opts.randomSeed = 0 ;
opts.profile = false ;
opts.parameterServer.method = 'mmap' ;
opts.parameterServer.prefix = 'mcn' ;
opts.errorFunction='';
opts.derOutputs = {'objective', 1} ;
opts.extractStatsFn = @extractStats ;
opts.plotStatistics = true;
opts.validLabelsError = 1;
opts.sync = false ;
opts.aug=false;
opts.colorAug.active=false;
opts.colorAug.dev=0;
opts.levels_update=-1;
opts = vl_argparse(opts, varargin) ;

if ~exist(opts.expDir, 'dir'), mkdir(opts.expDir) ; end
% if isempty(opts.train), opts.train = find(imdb.images.set==1) ; end
if isempty(opts.val), opts.val = find(imdb.images.set==2) ; end
if isnan(opts.train), opts.train = [] ; end
if isnan(opts.val), opts.val = [] ; end

% -------------------------------------------------------------------------
%                                                            Initialization
% -------------------------------------------------------------------------

evaluateMode = isempty(opts.train) ;
if ~evaluateMode
  if isempty(opts.derOutputs)
    error('DEROUTPUTS must be specified when training.\n') ;
  end
end

% -------------------------------------------------------------------------
%                                                        Train and validate
% -------------------------------------------------------------------------

modelPath = @(ep) fullfile(opts.expDir, sprintf('net-epoch-%d.mat', ep));
outPath = @(ep) fullfile(opts.expDir, sprintf('outs-epoch-%d.mat', ep));
modelFigPath = fullfile(opts.expDir, 'net-train.pdf') ;

start = opts.continue * findLastCheckpoint(opts.expDir) ;
if start >= 1
  fprintf('%s: resuming by loading epoch %d\n', mfilename, start) ;
  [net, state, stats] = loadState(modelPath(start)) ;
else
  state = [] ;
end

%If augmented test
if (opts.aug)
	aux_inputs=net.layers(end).inputs;
    aux_inputs{end+1}='imIdx';
    net.setLayerInputs('performance',aux_inputs);
end


%If we don't have train, we just run it once
if evaluateMode
    opts.numEpocs=start;
    opts.plotStatistics=false;
end
for epoch=start+1:opts.numEpochs

  % Set the random seed based on the epoch and opts.randomSeed.
  % This is important for reproducibility, including when training
  % is restarted from a checkpoint.

  rng(epoch + opts.randomSeed) ;
  prepareGPUs(opts, epoch == start+1) ;

  % Train for one epoch.
  params = opts ;
  params.epoch = epoch ;
  params.learningRate = opts.learningRate(min(epoch, numel(opts.learningRate))) ;
  params.train = opts.train(randperm(numel(opts.train))) ; % shuffle
  params.val = opts.val;%Don't shuffle 
  params.imdb = imdb ;
  params.getBatch = getBatch ;

  if numel(opts.gpus) <= 1
    [net, state] = processEpoch(net, net_seg, state, params, 'train') ;
    [net, state] = processEpoch(net, net_seg, state, params, 'val') ;
    if ~evaluateMode
      saveState(modelPath(epoch), net, state) ;
    end
    lastStats = state.stats ;
  else
    spmd
      [net, state] = processEpoch(net, net_seg, state, params, 'train') ;
      [net, state] = processEpoch(net, net_seg, state, params, 'val') ;
      if labindex == 1 && ~evaluateMode
        saveState(modelPath(epoch), net, state) ;
      end
      lastStats = state.stats ;
    end
    lastStats = accumulateStats(lastStats) ;
  end

  if ~evaluateMode
    stats.train(epoch) = lastStats.train ;
    stats.val(epoch) = lastStats.val ;
    clear lastStats ;
    saveStats(modelPath(epoch), stats) ;
  else
    saveOuts(outPath(epoch), state.outs) ;
  end
  if opts.plotStatistics
    switchFigure(1) ; clf ;
    plots = setdiff(...
      cat(2,...
      fieldnames(stats.train)', ...
      fieldnames(stats.val)'), {'num', 'time','aucs'},'stable') ;
    for p = plots
      p = char(p) ;
      values = zeros(0, epoch) ;
      leg = {} ;
      for f = {'train', 'val'}
        f = char(f) ;
        if isfield(stats.(f), p)
          tmp = [stats.(f).(p)] ;
          values(end+1,:) = tmp(1,:)' ;
          leg{end+1} = f ;
        end
      end
      subplot(1,numel(plots),find(strcmp(p,plots))) ;
      plot(1:epoch, values','o-') ;
      xlabel('epoch') ;
      title(p) ;
      legend(leg{:},'Location','northeast') ;
      grid on ;
    end
    drawnow ;
    print(1, modelFigPath, '-dpdf') ;
  end
  
end

% With multiple GPUs, return one copy
if isa(net, 'Composite'), net = net{1} ; end

% -------------------------------------------------------------------------
function [net, state] = processEpoch(net, net_seg, state, params, mode)
% -------------------------------------------------------------------------
% Note that net is not strictly needed as an output argument as net
% is a handle class. However, this fixes some aliasing issue in the
% spmd caller.

isSegDag =isa(net_seg,'dagnn.DagNN');
% initialize with momentum 0
if isempty(state) || isempty(state.momentum)
  state.momentum = num2cell(zeros(1, numel(net.params))) ;
end

% move CNN  to gpu as needed
numGpus = numel(params.gpus) ;
if numGpus >= 1
  net.move('gpu');
  if(isSegDag)
      net_seg.move('gpu');
  else
    net_seg = vl_simplenn_move(net_seg, 'gpu') ;
  end
  state.momentum = cellfun(@gpuArray, state.momentum, 'uniformoutput', false) ;
end
if numGpus > 1
  parserv = ParameterServer(params.parameterServer) ;
  net.setParameterServer(parserv) ;
else
  parserv = [] ;
end

% profile
if params.profile
  if numGpus <= 1
    profile clear ;
    profile on ;
  else
    mpiprofile reset ;
    mpiprofile on ;
  end
end

num = 0 ;
epoch = params.epoch ;
subset = params.(mode) ;

adjustTime = 0 ;

stats.num = 0 ; % return something even if subset = []
stats.time = 0 ;

%Resetting performance
net.layers(end).block.reset();
%For debugging
% if(~isempty(subset)),subset=subset(1:params.imdb.images.numVariations*10);end
start = tic ;
for t=1:params.batchSize:numel(subset)
  fprintf('%s: epoch %02d: %3d/%3d:', mode, epoch, ...
          fix((t-1)/params.batchSize)+1, ceil(numel(subset)/params.batchSize)) ;
  batchSize = min(params.batchSize, numel(subset) - t + 1) ;
  res_seg=[];
  for s=1:params.numSubBatches
    % get this image batch and prefetch the next
    batchStart = t + (labindex-1) + (s-1) * numlabs ;
    batchEnd = min(t+params.batchSize-1, numel(subset)) ;
    batch = subset(batchStart : params.numSubBatches * numlabs : batchEnd) ;
    num = num + numel(batch) ;
    if numel(batch) == 0, continue ; end
    
    inputs = params.getBatch(params.imdb, batch,'dagnn',params.colorAug) ;
    %Convert to GPU in case is necesary
    if numGpus >= 1
      for j=2:2:length(inputs)
          inputs{j}=gpuArray(inputs{j});
      end
    end
    
    %Set instance weights    
    if(length(inputs)>6 && ~params.aug)
        instanceWeights=inputs{8};
        net.layers(end-1).block.opts={'instanceWeights',reshape(instanceWeights,[1 1 1 length(instanceWeights)])};
    end
    if params.prefetch
      if s == params.numSubBatches
        batchStart = t + (labindex-1) + params.batchSize ;
        batchEnd = min(t+2*params.batchSize-1, numel(subset)) ;
      else
        batchStart = batchStart + numlabs ;
      end
      nextBatch = subset(batchStart : params.numSubBatches * numlabs : batchEnd) ;
      params.getBatch(params.imdb, nextBatch) ;
    end
    
    %If we need pcoords
    selCircpool = find(cellfun(@(x) isa(x,'dagnn.CircPoolingMask'), {net.layers.block}));
    if(~isempty(selCircpool))
        p = net.getParamIndex('pcoords');
        net.params(p).value=inputs{6};
        net.params(p).trainMethod='notrain';
    end
    %sel = find(cellfun(@(x) isa(x,'dagnn.Loss'), {net.layers.block}));
    %net.layers(sel(1)).block.opts={'instanceWeights',inputs{8}};
    
    %Just in case we have a modulation 
    sel = find(cellfun(@(x) isa(x,'dagnn.Modulation'), {net.layers.block}));
    sel = [sel, find(cellfun(@(x) isa(x,'dagnn.Fusion'), {net.layers.block}))];
    
    if(~isempty(sel))
        %CODE TO SAVE AND LOAD SEGMENTATIONS AND AVOID COMPUTING THEM EVERY
        %TIME
        [wmod readed]=loadSegmentations(params.imdb,batch);
%           reader=0;

        if(sum(readed)<length(readed))
            net_seg.meta.normalization.vdata_mean=reshape(net_seg.meta.normalization.vdata_mean,[1 1 3]);
            %First, execute the net_seg
            %%Feed-forward network
            if isSegDag==0
                sinputs=inputs{2}(:,:,:,~readed);
                %In case the normalization of net and seg_net is different
                if(sum(abs(net_seg.meta.normalization.vdata_mean-net.meta.normalization.vdata_mean))>1e-3)
                    sinputs=bsxfun(@plus,sinputs,net.meta.normalization.vdata_mean-net_seg.meta.normalization.vdata_mean);
                end
            
                res_seg = vl_simplenn_mask(net_seg, sinputs, inputs{6}(:,:,:,~readed), [], res_seg, ...
                    'accumulate', s ~= 1, ...
                    'mode', 'test', ...
                    'conserveMemory', true, ...
                    'backPropDepth', 1, ...
                    'sync', params.sync, ...
                    'cudnn', true, ...
                    'parameterServer', parserv, ...
                    'holdOn', s < params.numSubBatches) ;
                
                %Quit background
                if(~isempty(wmod))
                    wmod(:,:,:,~readed)=res_seg(end).x(:,:,2:end,:);
                else
                    wmod=res_seg(end).x(:,:,2:end,:);
                end
                res_seg=[];
            else
                
                sinputs={inputs{1},inputs{2}(:,:,:,~readed)};
                
                %In case the normalization of net and seg_net is different
                if(sum(abs(net_seg.meta.normalization.vdata_mean-net.meta.normalization.vdata_mean))>1e-3)
                    sinputs{2}=bsxfun(@plus,sinputs{2},net.meta.normalization.vdata_mean-net_seg.meta.normalization.vdata_mean);
                end
                net_seg.mode = 'test' ;
                net_seg.eval(sinputs);
                if(~isempty(wmod))
                    wmod(:,:,:,~readed)=net_seg.vars(end).value(:,:,2:end,:);
                else
                    wmod=net_seg.vars(end).value(:,:,2:end,~readed);
                end
            end
            
           saveSegmentations(params.imdb,batch,wmod);
        end
        %Reduce analysis to lession masks
        masks=inputs{6}(:,:,1,:)>0;
        masks = gpuArray(imresize(gather(masks),[size(wmod,1) size(wmod,2)],'Method','nearest'));
        wmod=bsxfun(@times,wmod,masks);
        
        
        %If there is a previous circpooling, we need to do the same
        %circpool here
        if(selCircpool<sel(1))
            pcoordsr=inputs{6}(:,:,:,:);
            pcoordsr(:,:,1,:)=bsxfun(@rdivide,pcoordsr(:,:,1,:),max(max(pcoordsr(:,:,1,:),[],1),[],2));
            pcoordsr(pcoordsr<=0)=1;
            pcoordsr = gpuArray(imresize(gather(pcoordsr),[size(wmod,1) size(wmod,2)]));
            wmod = vl_nncircpool_mask(wmod, pcoordsr, net.layers(selCircpool).block.poolSize, 'pad', net.layers(selCircpool).block.pad, 'overlap', [0 0], 'method', net.layers(selCircpool).block.method, net.layers(selCircpool).block.opts{:}) ;
        end
            
        %If we have a variable wmods
        v = net.getVarIndex('wmods');
        if(~isnan(v))
            net.vars(v).value=2*wmod;
            net.vars(v).trainMethod='notrain';
        end
        
        sel = find(cellfun(@(x) isa(x,'dagnn.Modulation'), {net.layers.block}));
        %If it is modulation
        if(isa(net.layers(sel(1)).block,'dagnn.Modulation'))
            
            %Sin máscara
            wmod = cat(3,ones(size(wmod,1),size(wmod,2),1,size(wmod,4),'single'),wmod);
            %Con máscara
            %             wmod = cat(3,masks,wmod);
            p = net.getParamIndex('wmods');
            net.params(p).value=wmod;
            net.params(p).trainMethod='notrain';
            clear wmod;
        elseif(isa(net.layers(sel(1)).block,'dagnn.Fusion'))
            net.layers{l}.wmod=wmod;
            %We normalize things to become zero mean and 1 std deviation
            %mult=size(net.layers{l-2}.weights{1},3)/size(wmod,3);
            wmod=vl_nnbnorm(net.layers{l}.wmod,gpuArray(ones(size(wmod,3), 1, 'single')), gpuArray(zeros(size(wmod,3), 1, 'single')),'epsilon', 1e-4) ;
            p = net.getParamIndex('wmods');
            net.params(p).value=wmod;
            net.params(p).trainMethod='notrain';
            clear wmod;
        end
        clear wmod;
        if(params.aug)
            inputs={inputs{1},inputs{2},inputs{3},inputs{4},inputs{7},inputs{8}};
        else
            inputs={inputs{1},inputs{2},inputs{3},inputs{4}};
        end
        
    else
        if(params.aug)
            inputs={inputs{1},inputs{2},inputs{3},inputs{4},inputs{7},inputs{8}};
        else
            inputs={inputs{1},inputs{2},inputs{3},inputs{4}};
        end
    end
   
    if strcmp(mode, 'train')
      net.mode = 'normal' ;
      net.accumulateParamDers = (s ~= 1) ;
      net.eval(inputs, params.derOutputs, 'holdOn', s < params.numSubBatches,'levels_update',params.levels_update) ;
    else
      net.mode = 'test' ;
      net.eval(inputs) ;
    end

  
  end


  % Accumulate gradient.
  if strcmp(mode, 'train')
    if ~isempty(parserv), parserv.sync() ; end
    state = accumulateGradients(net, state, params, batchSize, parserv) ;
  end

  % Get statistics.
  time = toc(start) + adjustTime ;
  batchTime = time - stats.time ;
  stats.num = num ;
  stats.time = time ;
  stats = params.extractStatsFn(stats,net) ;
  currentSpeed = batchSize / batchTime ;
  averageSpeed = (t + batchSize - 1) / time ;
  if t == 3*params.batchSize + 1
    % compensate for the first three iterations, which are outliers
    adjustTime = 4*batchTime - time ;
    stats.time = time + adjustTime ;
  end

  fprintf(' %.1f (%.1f) Hz', averageSpeed, currentSpeed) ;
  for f = setdiff(fieldnames(stats)', {'num', 'time'},'stable')
    f = char(f) ;
    fprintf(' %s: %.3f', f, stats.(f)(1)) ;
    for j=2:length(stats.(f))
        fprintf('  %.3f', stats.(f)(j)) ;
    end
  end
  fprintf('\n') ;
  
%   pindex=net.getParamIndex('fprediction_f');
%   squeeze(net.params(pindex).value)
    
end

 


% Save back to state.
state.stats.(mode) = stats ;
if params.profile
  if numGpus <= 1
    state.prof.(mode) = profile('info') ;
    profile off ;
  else
    state.prof.(mode) = mpiprofile('info');
    mpiprofile off ;
  end
end
if ~params.saveMomentum
  state.momentum = [] ;
else
  state.momentum = cellfun(@gather, state.momentum, 'uniformoutput', false) ;
end

if ~strcmp(mode, 'train')
    state.outs=[];
    state.outs.labels=net.layers(end).block.labels;
    state.outs.predictions=net.layers(end).block.predictions;
    state.outs.imIDs=net.layers(end).block.imIDs;
else
    state.outs=[];
end
    
net.reset() ;
net.move('cpu') ;

% -------------------------------------------------------------------------
function state = accumulateGradients(net, state, params, batchSize, parserv)
% -------------------------------------------------------------------------
numGpus = numel(params.gpus) ;
otherGpus = setdiff(1:numGpus, labindex) ;

for p=1:numel(net.params)

  if ~isempty(parserv)
    parDer = parserv.pullWithIndex(p) ;
  else
    parDer = net.params(p).der ;
  end

  switch net.params(p).trainMethod

    case 'average' % mainly for batch normalization
      thisLR = net.params(p).learningRate ;
      if thisLR>0 
          net.params(p).value = vl_taccum(...
              1 - thisLR, net.params(p).value, ...
              (thisLR/batchSize/net.params(p).fanout),  parDer) ;
      end

    case 'gradient'
      thisDecay = params.weightDecay * net.params(p).weightDecay ;
      thisLR = params.learningRate * net.params(p).learningRate ;

      if thisLR>0 || thisDecay>0        
        % Normalize gradient and incorporate weight decay.
        parDer = vl_taccum(1/batchSize, parDer, ...
                           thisDecay, net.params(p).value) ;
        % Update momentum.
        state.momentum{p} = vl_taccum(...
          params.momentum, state.momentum{p}, ...
          -1, parDer) ;

        % Nesterov update (aka one step ahead).
        if params.nesterovUpdate
          delta = vl_taccum(...
            params.momentum, state.momentum{p}, ...
            -1, parDer) ;
        else
          delta = state.momentum{p} ;
        end

        % Update parameters.
        net.params(p).value = vl_taccum(...
          1,  net.params(p).value, thisLR, delta) ;
      end

    otherwise
      error('Unknown training method ''%s'' for parameter ''%s''.', ...
        net.params(p).trainMethod, ...
        net.params(p).name) ;
  end
end

% -------------------------------------------------------------------------
function stats = accumulateStats(stats_)
% -------------------------------------------------------------------------

for s = {'train', 'val'}
  s = char(s) ;
  total = 0 ;

  % initialize stats stucture with same fields and same order as
  % stats_{1}
  stats__ = stats_{1} ;
  names = fieldnames(stats__.(s))' ;
  values = zeros(1, numel(names)) ;
  fields = cat(1, names, num2cell(values)) ;
  stats.(s) = struct(fields{:}) ;

  for g = 1:numel(stats_)
    stats__ = stats_{g} ;
    num__ = stats__.(s).num ;
    total = total + num__ ;

    for f = setdiff(fieldnames(stats__.(s))', 'num')
      f = char(f) ;
      stats.(s).(f) = stats.(s).(f) + stats__.(s).(f) * num__ ;

      if g == numel(stats_)
        stats.(s).(f) = stats.(s).(f) / total ;
      end
    end
  end
  stats.(s).num = total ;
end

% -------------------------------------------------------------------------
function stats = extractStats(stats, net)
% -------------------------------------------------------------------------
sel = find(cellfun(@(x) isa(x,'dagnn.Loss'), {net.layers.block})) ;
for i = 1:numel(sel)
  stats.(net.layers(sel(i)).outputs{1}) = net.layers(sel(i)).block.average ;
  if(isprop(net.layers(sel(i)).block,'perfs'))
      stats.([net.layers(sel(i)).outputs{1} 's']) = net.layers(sel(i)).block.perfs ;
  end
end

% -------------------------------------------------------------------------
function saveState(fileName, net_, state)
% -------------------------------------------------------------------------
net = net_.saveobj() ;
save(fileName, 'net', 'state') ;

% -------------------------------------------------------------------------
function saveStats(fileName, stats)
% -------------------------------------------------------------------------
if exist(fileName)
  save(fileName, 'stats', '-append') ;
else
  save(fileName, 'stats') ;
end

% -------------------------------------------------------------------------
function saveOuts(fileName, outs)
% -------------------------------------------------------------------------
if exist(fileName)
  save(fileName, 'outs', '-append') ;
else
  save(fileName, 'outs') ;
end

% -------------------------------------------------------------------------
function [net, state, stats] = loadState(fileName)
% -------------------------------------------------------------------------
load(fileName, 'net', 'state', 'stats') ;
net = dagnn.DagNN.loadobj(net) ;
if isempty(whos('stats'))
  error('Epoch ''%s'' was only partially saved. Delete this file and try again.', ...
        fileName) ;
end

% -------------------------------------------------------------------------
function epoch = findLastCheckpoint(modelDir)
% -------------------------------------------------------------------------
list = dir(fullfile(modelDir, 'net-epoch-*.mat')) ;
tokens = regexp({list.name}, 'net-epoch-([\d]+).mat', 'tokens') ;
epoch = cellfun(@(x) sscanf(x{1}{1}, '%d'), tokens) ;
epoch = max([epoch 0]) ;

% -------------------------------------------------------------------------
function switchFigure(n)
% -------------------------------------------------------------------------
if get(0,'CurrentFigure') ~= n
  try
    set(0,'CurrentFigure',n) ;
  catch
    figure(n) ;
  end
end

% -------------------------------------------------------------------------
function clearMex()
% -------------------------------------------------------------------------
clear vl_tmove vl_imreadjpeg ;

% -------------------------------------------------------------------------
function prepareGPUs(opts, cold)
% -------------------------------------------------------------------------
numGpus = numel(opts.gpus) ;
if numGpus > 1
  % check parallel pool integrity as it could have timed out
  pool = gcp('nocreate') ;
  if ~isempty(pool) && pool.NumWorkers ~= numGpus
    delete(pool) ;
  end
  pool = gcp('nocreate') ;
  if isempty(pool)
    parpool('local', numGpus) ;
    cold = true ;
  end

end
if numGpus >= 1 && cold
  fprintf('%s: resetting gpu\n', mfilename)
  clearMex() ;
  if numGpus == 1
    gpuDevice(opts.gpus)
  else
    spmd
      clearMex() ;
      gpuDevice(opts.gpus(labindex))
    end
  end
end


function [wmod, read]=loadSegmentations(imdb,batch)
[folder fname ext]=fileparts(imdb.images.paths{batch(1)});
numIm=length(batch);
wmod=[];
read=zeros(numIm,1);
for i=1:numIm
	sFile=regexprep(imdb.images.paths{batch(i)},'db_images','db_segs');
	if(exist(sFile,'file'))
    	aux=load(sFile,'wmod');
		[H W C]=size(aux.wmod);
		if(isempty(wmod))
			wmod=gpuArray(zeros(H,W,C,numIm,'single'));
		end
		wmod(:,:,:,i)=aux.wmod;
		read(i)=1;
	end
end


function saveSegmentations(imdb,batch,wmods)

numIm=length(batch);
wmod=[];
for i=1:numIm
    [folder fname ext]=fileparts(imdb.images.paths{batch(i)});
    sfolder=regexprep(folder,'db_images','db_segs');
    if(~exist(sfolder,'dir'))
        mkdir(sfolder);
    end
	sFile=regexprep(imdb.images.paths{batch(i)},'db_images','db_segs');
	if(~exist(sFile,'file'))
    	wmod=wmods(:,:,:,i);
		save(sFile,'wmod');
	end
end

