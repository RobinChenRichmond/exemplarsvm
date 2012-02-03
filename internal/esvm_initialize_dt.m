function models = esvm_initialize_dt(data_set, cls, params)
% DalalTriggs model creation which creates an initial positive set and
% by warping positives into a single canonical position, where the
% canonical position is the obtained from statistics of bounding box
% aspect ratios
%
% INPUTS:
% data_set: the training set of objects
% cls: the target category from which we extract positives and
%   use remaining images to define negatives
% params [optional]: the parameters
%
% OUTPUTS:
% models: A single DalalTriggs model, so length(models)==1
%
% Copyright (C) 2011-12 by Tomasz Malisiewicz
% All rights reserved.
% 
% This file is part of the Exemplar-SVM library and is made
% available under the terms of the MIT license (see COPYING file).
% Project homepage: https://github.com/quantombone/exemplarsvm

%save with dt as the model name
models_name = [cls '-dt'];
  
if length(params.localdir)>0
  CACHE_FILE = 1;
else
  CACHE_FILE = 0;
  params.localdir = '';
end

if ~exist('models_name','var')
  models_name = '';
end

cache_dir =  ...
    sprintf('%s/models/',params.localdir);

cache_file = ...
    sprintf('%s/%s.mat',cache_dir,models_name);

if CACHE_FILE ==1 && fileexists(cache_file)
  models = load(cache_file);
  models = models.models;
  return;
end

results_directory = ...
    sprintf('%s/models/',params.localdir);

if CACHE_FILE==1 && ~exist(results_directory,'dir')
  fprintf(1,'Making directory %s\n',results_directory);
  mkdir(results_directory);
end

filer = sprintf('%s/%s.mat', results_directory, models_name);
filerlock = [filer '.lock'];

if CACHE_FILE == 1
  if fileexists(filer) 
    m = load(filer);
    models = m.models;
    return;
  end
end

tic
[cur_pos_set, ~, data_set] = get_objects_set(data_set, cls);
toc

% fprintf(1,['TJM(HACK) choosing subset of 10 instances to make things' ...
%            ' faster \n']);

% %Set dataset to be the pruned dataset with only positives loaded
% data_set = cur_pos_set(1:10);
% cur_pos_set = cur_pos_set(1:10);

fprintf(1,'HACK choosing solo positive set\n');
m.data_set = cur_pos_set;

hg_size = get_hg_size(cur_pos_set, params.init_params.sbin);

curfeats = cell(0,1);
bbs = cell(0,1);
fprintf(1,['esvm_initialize_dt: initializing features by' ...
           ' warping to a canonical size\n']);

for j = 1:length(data_set)  
  obj = {data_set{j}.objects};
  
  %Skip positive generation if there are no objects
  if length(data_set{j}.objects) == 0
    continue
  end
  I = toI(data_set{j}.I);
  flipI = flip_image(I);
  
  for k = 1:length(obj)
    
    % Warp original bounding box
    bbox = obj{k}.bbox;    
    warped1 = mywarppos(hg_size, I, params.init_params.sbin, bbox);
    curfeats{end+1} = params.init_params.features(warped1, ...
                                                  params ...
                                                  .init_params.sbin);
    bbox(11) = j;
    bbox(12) = 0;
    bbs{end+1} = bbox;

    % Warp LR flipped version
    bbox2 = flip_box(bbox,size(I));
    warped2 = mywarppos(hg_size, flipI, params.init_params.sbin, bbox2);
    curfeats{end+1} = params.init_params.features(warped2, ...
                                                  params.init_params ...
                                                  .sbin);
    bbox2(11) = j;
    bbox2(12) = 0;
    bbs{end+1} = bbox2;
    
    fprintf(1,'.');
  end
end  

fprintf(1,'esvm_initialize_dt: finished with %d windows\n',length(curfeats));
curfeats = cellfun2(@(x)reshape(x,[],1),curfeats);
curfeats = cat(2,curfeats{:});
m.cls = cls;
m.models_name = models_name;
m.params = params;

m.hg_size = [hg_size params.init_params.features()];
m.mask = ones(m.hg_size(1),m.hg_size(2));

%positive features: x
m.x = curfeats;

%positive windows: bb
m.bb = cat(1,bbs{:});

%negative features: svxs
m.svxs = [];

%negative windows: svbbs
m.svbbs = [];

%create an initial classifier
m.w = mean(curfeats,2);
m.w = m.w - mean(m.w(:));
m.w = reshape(m.w, m.hg_size);
m.b = 0;

%m.name = sprintf('dt-%s',m.cls);
%m.curid = m.cls;
%m.objectid = -1;
%m.data_set = data_set;
models = {m};

if CACHE_FILE == 1
  save(filer,'models');
  if fileexists(filerlock)
    rmdir(filerlock);
  end
end

function [hg_size] = get_hg_size(pos_set, sbin)
%% Load ids of all images in trainval that contain cls

r =cellfun2(@(x)cat(1,x.objects.bbox),pos_set);
bbs =cat(1,r{:});

W = bbs(:,3)-bbs(:,1)+1;
H = bbs(:,4)-bbs(:,2)+1;

[hg_size,aspect_ratio_histogram] = get_bb_stats(H, W, sbin);


function [modelsize,aspects] = get_bb_stats(h,w, sbin)
% Following Felzenszwalb's formula

xx = -2:.02:2;
filter = exp(-[-100:100].^2/400);
aspects = hist(log(h./w), xx);
aspects = convn(aspects, filter, 'same');
[peak, I] = max(aspects);
aspect = exp(xx(I));

% pick 20 percentile area
areas = sort(h.*w);
%TJM: make sure we index into first element if not enough are
%present to take the 20 percentile area
area = areas(max(1,floor(length(areas) * 0.2)));
area = max(min(area, 5000), 3000);

% pick dimensions
w = sqrt(area/aspect);
h = w*aspect;

modelsize = [round(h/sbin) round(w/sbin)];

function warped = mywarppos(hg_size, I, sbin, bbox)
% warped = mywarppos(name, model, c, pos)
% Warp positive examples to fit model dimensions.
% Used for training root filters from positive bounding boxes.
% Taken from Felzenszwalb et al's code

pixels = hg_size * sbin;
h = bbox(4) - bbox(2) + 1;
w = bbox(3) - bbox(1) + 1;

cropsize = (hg_size+2) * sbin;

padx = sbin * w / pixels(2);
pady = sbin * h / pixels(1);
x1 = round(bbox(1)-padx);
x2 = round(bbox(3)+padx);
y1 = round(bbox(2)-pady);
y2 = round(bbox(4)+pady);
window = subarray(I, y1, y2, x1, x2, 1);
warped = imresize(window, cropsize(1:2), 'bilinear');