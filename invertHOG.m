% invertHOG(feat)
%
% This function recovers the natural image that may have generated the HOG
% feature 'feat'. Usage is simple:
%
%   >> feat = features(im, 8);
%   >> ihog = invertHOG(feat);
%   >> imagesc(ihog); axis image;
%
% By default, invertHOG() will load a prelearned paired dictionary to perform
% the inversion. However, if you want to pass your own, you can specify the
% optional second parameter to use your own parameters:
% 
%   >> pd = learnpairdict('/path/to/images');
%   >> ihog = invertHOG(feat, pd);
%
% This function should take no longer than a second to invert any reasonably sized
% HOG feature point on a 12 core machine.
%
% If you have many points you wish to invert, this function can be vectorized.
% If 'feat' is size AxBxCxK, then it will invert K HOG features each of size
% AxBxC. It will return an PxQxK image tensor where the last channel is the kth
% inversion. This is usually significantly faster than calling invertHOG() 
% multiple times.
function [im, prev] = invertHOG(feat, pd, prev),

if ~exist('prev', 'var'),
  prev.a = zeros(0, 0, 0);
end
if ~isfield(prev, 'gam'),
  prev.gam = 10;
end
if ~isfield(prev, 'sig'),
  prev.sig = 1;
end

prevnum = size(prev.a, 3);
prevnuma = size(prev.a, 2);

if ~exist('pd', 'var') || isempty(pd),
  global ihog_pd
  if isempty(ihog_pd),
    if ~exist('pd.mat', 'file'),
      fprintf('ihog: notice: unable to find paired dictionary\n');
      fprintf('ihog: notice: attempting to download in 3');
      pause(1); fprintf('\b2'); pause(1); fprintf('\b1'); pause(1);
      fprintf('\b0\n');
      fprintf('ihog: notice: downloading...');
      urlwrite('http://people.csail.mit.edu/vondrick/pd.mat', 'pd.mat');
      fprintf('done\n');
    end
    ihog_pd = load('pd.mat');
  end
  pd = ihog_pd;
end

par = 5;
feat = padarray(feat, [par par 0 0], 0);

[ny, nx, ~, nn] = size(feat);

% pad feat if dim lacks occlusion feature
if size(feat,3) == computeHOG()-1,
  feat(:, :, end+1, :) = 0;
end

% extract every window 
windows = zeros(pd.ny*pd.nx*computeHOG(), (ny-pd.ny+1)*(nx-pd.nx+1)*nn);
c = 1;
for k=1:nn,
  for i=1:size(feat,1) - pd.ny + 1,
    for j=1:size(feat,2) - pd.nx + 1,
      hog = feat(i:i+pd.ny-1, j:j+pd.nx-1, :, k);
      hog = hog(:) - mean(hog(:));
      hog = hog(:) / sqrt(sum(hog(:).^2) + eps);
      windows(:,c)  = hog(:);
      c = c + 1;
    end
  end
end

% incorporate constraints for multiple inversions
dhog = pd.dhog;
mask = logical(ones(size(windows)));
if prevnum > 0,
  % build blurred dictionary
  if prev.sig > 0,
    dblur = xpassdict(pd, prev.sig, false);
  elseif prev.sig < 0,
    dblur = xpassdict(pd, -prev.sig, true);
  end

  windows = padarray(windows, [prevnum*prevnuma 0], 0, 'post');
  mask = cat(1, mask, repmat(logical(eye(prevnuma, size(windows,2))), [prevnum 1]));
  offset = size(dhog, 1);
  dhog = padarray(dhog, [prevnum*prevnuma 0], 0, 'post');
  for i=1:prevnum,
    dhog(offset+(i-1)*prevnuma+1:offset+i*prevnuma, :) = sqrt(prev.gam) * prev.a(:, :, i)' * dblur' * dblur;
  end
end

% solve lasso problem
param.lambda = pd.lambda * size(windows,1) / (pd.ny*pd.nx*computeHOG() + prevnum);
param.mode = 2;
param.pos = true;
a = full(mexLassoMask(single(windows), dhog, mask, param));
recon = pd.dgray * a;

% reconstruct
fil     = fspecial('gaussian', [(pd.ny+2)*pd.sbin (pd.nx+2)*pd.sbin], 9);
im      = zeros((size(feat,1)+2)*pd.sbin, (size(feat,2)+2)*pd.sbin, nn);
weights = zeros((size(feat,1)+2)*pd.sbin, (size(feat,2)+2)*pd.sbin, nn);
c = 1;
for k=1:nn,
  for i=1:size(feat,1) - pd.ny + 1,
    for j=1:size(feat,2) - pd.nx + 1,
      patch = reshape(recon(:, c), [(pd.ny+2)*pd.sbin (pd.nx+2)*pd.sbin]);
      patch = patch .* fil;

      iii = (i-1)*pd.sbin+1:(i-1)*pd.sbin+(pd.ny+2)*pd.sbin;
      jjj = (j-1)*pd.sbin+1:(j-1)*pd.sbin+(pd.nx+2)*pd.sbin;

      im(iii, jjj, k) = im(iii, jjj, k) + patch;
      weights(iii, jjj, k) = weights(iii, jjj, k) + 1;

      c = c + 1;
    end
  end
end

% post processing averaging and clipping
im = im ./ weights;
im = im(1:(ny+2)*pd.sbin, 1:(nx+2)*pd.sbin, :);
for k=1:nn,
  img = im(:, :, k);
  img(:) = img(:) - min(img(:));
  img(:) = img(:) / max(img(:));
  im(:, :, k) = img;
end

im = im(par*pd.sbin:end-par*pd.sbin-1, par*pd.sbin:end-par*pd.sbin-1, :);

im = repmat(im, [1 1 1 3]);
im = permute(im, [1 2 4 3]);

% build previous information
if prev.num > 0,
  prev.a = cat(3, prev.a, a);
else,
  prev.a = a;
end
