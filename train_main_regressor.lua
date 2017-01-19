require 'cunn'
require 'cudnn'
require 'cutorch'
local Runner = require 'runner_regressor'

torch.setdefaulttensortype('torch.FloatTensor')

local save_parameters = {'weight', 'bias', 'running_mean', 'running_var', 'running_std' }

local function copyModel(src, dst)
	assert(torch.type(src) == torch.type(dst), 'torch.type(src) ~= torch.type(dst)')
	for i,k in ipairs(save_parameters) do
		local v = src[k]
		if v ~= nil then
			dst[k]:copy(v)
		end
	end
	if src.modules ~= nil then
		assert(#dst.modules == #src.modules, '#dst.modules ~= #src.modules')
		local nModule = #src.modules
		if nModule > 0 then
			for i=1,nModule do
				copyModel(src.modules[i], dst.modules[i])
			end
		end
	end
end

local dataDir = '/home/xiaofei/public_datasets/MICCAI_tool/Tracking_Robotic_Training/tool_label'
if not paths.dirp(dataDir) then
	error("Can't find directory : " .. dataDir)
end
local saveDir = '/home/xiaofei/workspace/toolPose/models'
if not paths.dirp(saveDir) then
	os.execute('mkdir -p ' .. saveDir)
end

local function getSaveID(modelConf)
    local s = modelConf.type
    if modelConf.iterCnt ~= nil then
        s = s .. '_i' .. modelConf.iterCnt
    end
    s = s .. '_v' .. modelConf.v
    return s
end

local opt = {
	dataDir = dataDir,
	saveDir = saveDir,
	retrain = 'last', -- nil, 'last' or 'best'
	learningRate = 1e-3,  -- old 1e-5
	momentum = 0.9,
	weightDecay = 0.0005, -- old 0.0005
	decayRatio = 0.95,
	updateIternal = 10,
    detModelConf = {type='toolDualPoseSep', v=1},
	modelConf = {type='toolPoseRegress', v=1},
	gpus = {1},
	nThreads = 6,
--	batchSize = 1,  --  examples seems to be the maximum setting for one GPU
	trainBatchSize = 5,
	valBatchSize = 5,
	inputWidth = 480, --720,
	inputHeight = 384, -- 576,
	rotMaxDegree = 0,
	jointRadius = 20,
    toolJointNames = {'LeftClasperPoint', 'RightClasperPoint',
                          'HeadPoint', 'ShaftPoint', 'EndPoint' }, -- joint number = 5
	toolCompoNames = {{'LeftClasperPoint', 'HeadPoint'},
					  {'RightClasperPoint', 'HeadPoint'},
					  {'HeadPoint', 'ShaftPoint'},
                      {'ShaftPoint', 'EndPoint'}
					 },
	nEpoches = 300
}

local detID = getSaveID(opt.detModelConf)
local detModelPath = paths.concat(opt.saveDir, 'model.' .. detID .. '.best.t7')

local saveID = getSaveID(opt.modelConf)
local initModelPath = paths.concat(opt.saveDir, 'model.' .. saveID .. '.init.t7')
local lastModelPath = paths.concat(opt.saveDir, 'model.' .. saveID .. '.last.t7')
local lastOptimStatePath = paths.concat(opt.saveDir, 'optim.' .. saveID .. '.last.t7')
local bestModelPath = paths.concat(opt.saveDir, 'model.' .. saveID .. '.best.t7')
local bestOptimStatePath = paths.concat(opt.saveDir, 'optim.' .. saveID .. '.best.t7')
local loggerPath = paths.concat(opt.saveDir, 'log.' .. saveID .. '.t7')
local logPath = paths.concat(opt.saveDir, 'log.' .. saveID .. '.txt')

local function getDetModelPath()
    local modelPath
--	print(detModelPath)
    if paths.filep(detModelPath) then
        modelPath = detModelPath
	end
    print('current using detection model: ' .. modelPath)
    return modelPath
end
local function getModelPath()
    local modelPath
    if opt.retrain == 'last' and paths.filep(lastModelPath) then
        modelPath = lastModelPath
    elseif opt.retrain == 'best' and paths.filep(bestModelPath) then
        modelPath = bestModelPath
    else
        modelPath = initModelPath
	end
	print('current using model: ' .. modelPath)
    return modelPath
end

local function getModel()
    local model = torch.load(getModelPath())
    return model
end

local function getOptimState()
	local optimState
	if opt.retrain == 'last' and paths.filep(lastOptimStatePath) then
		optimState = torch.load(lastOptimStatePath)
--		optimState.learningRate = 1e-5
	elseif opt.retrain == 'best' and paths.filep(bestOptimStatePath) then
		optimState = torch.load(bestOptimStatePath)
	else
		optimState = {
			learningRate = opt.learningRate,
			weightDecay = opt.weightDecay,
			momentum = opt.momentum,
			dampening = 0.0,
			nesterov = true,
			epoch = 0
		}
	end
	return optimState
end

-- when saving, clear the potential tensors in the optim state
local function saveOptimState(save_path, optim_state)
	local optimState = {}
	for key, value in pairs(optim_state) do
		if not torch.isTensor(value) then
			optimState[key] = value
		end
	end
	torch.save(save_path, optimState)
end

local detModel_path = getDetModelPath()
local model_path = getModelPath()
local model
local runningState = {valAcc=0, model = getModel(), optimState = getOptimState() }

-- The runner handles the training loop and evaluate on the val set
local runner = Runner(detModel_path, model_path, opt, runningState.optimState)
model = runner:getModel()
print('optim State: ')
print(runningState.optimState)
local best_epoch = runningState.optimState.epoch
local logFile = io.open(logPath, 'w')
local logger = torch.FloatTensor(opt.nEpoches, 5)

-- Run model on validation set
local valAcc, valLoss, valPrec = runner:val(0)
print(string.format("Val : robustness accuracy = %.3f, loss = %.5f", valAcc, valLoss))
print(string.format("Val : precision distance = %.3f", valPrec))


for epoch = 1, opt.nEpoches do
    print('\nepoch # ' .. epoch)

    -- train for a single epoch
	local trainAcc, trainLoss, valAcc, valLoss, testAcc, testLoss = 0, 0, 0, 0, 0, 0
	local trainPrec, valPrec = 1e+8, 1e+8
    trainAcc, trainLoss, trainPrec = runner:train(epoch)
    print(string.format("Train : robustness accuracy = %.3f, loss = %.5f", trainAcc, trainLoss))
	print(string.format("Train : precision distance = %.3f", trainPrec))

	-- Run model on validation set
    valAcc, valLoss, valPrec = runner:val(epoch)
    print(string.format("Val : robustness accuracy = %.3f, loss = %.5f", valAcc, valLoss))
	print(string.format("Val : precision distance = %.3f", valPrec))
	testAcc, testLoss = runner:test(epoch)
	print(string.format("Test : test random Sample."))


--	copyModel(model, runningState.model)
--	torch.save(lastModelPath, runningState.model)
	torch.save(lastModelPath, model:clearState())
	saveOptimState(lastOptimStatePath, runningState.optimState)

	logger[epoch][1] = runningState.optimState.epoch
	logger[epoch][2] = trainAcc
	logger[epoch][3] = valAcc
	logger[epoch][4] = trainLoss
	logger[epoch][5] = valLoss
	logFile:write(string.format('%d %.3f %.3f %.5f %.5f\n',
	logger[epoch][1], logger[epoch][2], logger[epoch][3], logger[epoch][4], logger[epoch][5]))
	logFile:flush()
	torch.save(loggerPath, logger)


	print('optim State for this epoch: ')
	print(runningState.optimState)

	print(string.format("Train : robustness accuracy = %.3f, loss = %.5f", trainAcc, trainLoss))
	print(string.format("Train : precision distance = %.3f", trainPrec))
	print(string.format("Val : robustness accuracy = %.3f, loss = %.5f", valAcc, valLoss))
	print(string.format("Val : precision distance = %.3f", valPrec))

	if valAcc > runningState.valAcc then
		print('Saving the best! ')
		best_epoch = runningState.optimState.epoch
		runningState.valAcc = valAcc
--		torch.save(bestModelPath, runningState.model)
		torch.save(bestModelPath, model:clearState())
		saveOptimState(bestOptimStatePath, runningState.optimState)
    end
end
logFile:write(string.format('bestModel.epoch = %d, bestModel.valAcc = %.3f', best_epoch, runningState.valAcc))
logFile:flush()
logFile:close()

-- copy the log file
local logFinalPath = paths.concat(opt.saveDir, 'log.' .. saveID .. '_ep' .. runningState.optimState.epoch .. '.txt')
local inlogFile = io.open(logPath, 'r')
local instr = inlogFile:read('*a')
inlogFile:close()
local outlogFile = io.open(logFinalPath, 'w')
outlogFile:write(instr)
outlogFile:close()

logger = nil
runningState.model = nil
runningState.optimState = nil
model = nil
