--[[

Copyright (c) 2021, TU Delft

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.


name: modROS.lua
version: 0.0.1
description:
This mod for Farming Simulator 2019 allows autonomous driving of FarmSim vehicles with the ROS navigation stack.
There are three console commands in this mod for now:
The first one is to publish data, the second one is to subscribe data and the last one is to force-center the camera
------------------------------------------------
------------------------------------------------

A: Publishing data
1. sim time publisher - publish the farmsim time
2. odom publisher - publish the odom data from the game
3. laser scan publisher - publish the laser scan data (64 rays)
4. imu publisher - publish the imu data (especially the acc info)
5. TF publisher - publish tf
6. A command for writing all messages to a named pipe: "rosPubMsg true/false"
------------------------------------------------
------------------------------------------------

B. Subscribing data
1. ros_cmd_teleop subscriber - give the vehicle control to ROS'
2. A command for taking over control of a vehicle in the game : "rosControlVehicle true/false"

------------------------------------------------
------------------------------------------------

C. Force-centering the camera
1. A command for force-centering the current camera: "forceCenteredCamera true/false"

------------------------------------------------
------------------------------------------------

author: Ting-Chia Chiang, G.A. vd. Hoorn
maintainer: Ting-Chia Chiang, G.A. vd. Hoorn


--]]

ModROS = {}
ModROS.MOD_DIR = g_modROSModDirectory
ModROS.MOD_NAME = g_modROSModName
ModROS.MOD_VERSION = g_modManager.nameToMod[ModROS.MOD_NAME]["version"]

local function center_camera_func()
    local camIdx = g_currentMission.controlledVehicle.spec_enterable.camIndex
    local camera = g_currentMission.controlledVehicle.spec_enterable.cameras[camIdx]
    camera.rotX = camera.origRotX
    camera.rotY = camera.origRotY
end

function ModROS:loadMap()
    self.last_read = ""
    self.buf = SharedMemorySegment:init(64)
    self.sec = 0
    self.nsec = 0
    self.l_v_x_0 = 0
    self.l_v_y_0 = 0
    self.l_v_z_0 = 0

    -- initialise connection to the Python side (but do not connect it yet)
    self.path = ModROS.MOD_DIR .. "ROS_messages"
    self._conx = WriteOnlyFileConnection.new(self.path)

    -- initialise publishers
    self._pub_tf = Publisher.new(self._conx, "tf", tf2_msgs_TFMessage)
    self._pub_clock = Publisher.new(self._conx, "clock", rosgraph_msgs_Clock)
    self._pub_odom = Publisher.new(self._conx, "odom", nav_msgs_Odometry)
    self._pub_scan = Publisher.new(self._conx, "scan", sensor_msgs_LaserScan)
    self._pub_imu = Publisher.new(self._conx, "imu", sensor_msgs_Imu)

    print("modROS (" .. ModROS.MOD_VERSION .. ") loaded")
end

function ModROS.installSpecializations(vehicleTypeManager, specializationManager, modDirectory, modName)
    specializationManager:addSpecialization("rosVehicle", "RosVehicle", Utils.getFilename("src/vehicles/RosVehicle.lua", modDirectory), nil) -- Nil is important here

    for typeName, _ in pairs(vehicleTypeManager:getVehicleTypes()) do
        vehicleTypeManager:addSpecialization(typeName, modName .. ".rosVehicle")
    end

end

function ModROS:update(dt)
    -- create TFMessage object
    self.tf_msg = tf2_msgs_TFMessage.new()

    if self.doPubMsg then
        -- avoid writing to the pipe if it isn't actually open
        -- avoid publishing data if one is not inside a vehicle
        if self._conx:is_connected() and g_currentMission.controlledVehicle ~= nil then
            self:publish_sim_time_func()
            self:publish_veh_func()
            self:publish_laser_scan_func()
            -- self:publish_imu_func()
            self._pub_tf:publish(self.tf_msg)

        end
    end

    if self.doRosControl then
        self:subscribe_ROScontrol_manned_func(dt)
    end
    if self.doCenterCamera then
        if g_currentMission.controlledVehicle == nil then
            print("You have left your vehicle! Stop force-centering camera")
            self.doCenterCamera = false
        else
            center_camera_func()
        end
    end
end

--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- A.1 sim_time publisher (TODO:add description)
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]
function ModROS:publish_sim_time_func()
    local msg = rosgraph_msgs_Clock.new()
    msg.clock = ros.Time.now()
    self._pub_clock:publish(msg)
end

--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- A.2. odom publisher (TODO:add description)
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]
-- a function to publish get the position and orientaion of unmanned or manned vehicle(s) get and write to the named pipe (symbolic link)
function ModROS:publish_veh_func()
    for _, vehicle in pairs(g_currentMission.vehicles) do
        local ros_time = ros.Time.now()
        vehicle:pubOdom(ros_time, self.tf_msg, self._pub_odom)
    end
end

--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- A.3. laser scan publisher  (TODO:add description)
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]

-- B.3. laser scan publisher
function ModROS:publish_laser_scan_func()

    if mod_config.control_only_active_one then
        local vehicle = g_currentMission.controlledVehicle
        local ros_time = ros.Time.now()
        vehicle:fillLaserData(ros_time, self.tf_msg, self._pub_scan)
    else
        for _, vehicle in pairs(g_currentMission.vehicles) do
            local ros_time = ros.Time.now()
            vehicle:fillLaserData(ros_time, self.tf_msg, self._pub_scan)
        end
    end
end


--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- A.4. imu publisher (TODO:add description)
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]
-- a function to publish get the position and orientaion of unmanned or manned vehicle(s) get and write to the named pipe (symbolic link)
function ModROS:publish_imu_func()
    local vehicle = g_currentMission.controlledVehicle

    -- retrieve the vehicle node we're interested in
    local veh_node = vehicle.components[1].node

    -- retrieve global (ie: world) coordinates of this node
    local q_x, q_y, q_z, q_w = getWorldQuaternion(veh_node)

    -- get twist data and calculate acc info

    -- check getVelocityAtWorldPos and getVelocityAtLocalPos
    -- local linear vel: Get velocity at local position of transform object; "getLinearVelocity" is the the velocity wrt world frame
    -- local l_v_z max is around 8(i guess the unit is m/s here) when reach 30km/hr(shown in speed indicator)
    local l_v_x, l_v_y, l_v_z = getLocalLinearVelocity(veh_node)
    -- we don't use getAngularVelocity(veh_node) here as the return value is wrt the world frame not local frame

    -- TODO add condition to filter out the vehicle: train because it does not have velocity info
    -- for now we'll just use 0.0 as a replacement value
    if not l_v_x then l_v_x = 0.0 end
    if not l_v_y then l_v_y = 0.0 end
    if not l_v_z then l_v_z = 0.0 end

    -- calculation of linear acceleration in x,y,z directions
    local acc_x = (l_v_x - self.l_v_x_0) / (g_currentMission.environment.dayTime / 1000 - self.sec)
    local acc_y = (l_v_y - self.l_v_y_0) / (g_currentMission.environment.dayTime / 1000 - self.sec)
    local acc_z = (l_v_z - self.l_v_z_0) / (g_currentMission.environment.dayTime / 1000 - self.sec)
    -- update the velocity and time
    self.l_v_x_0 = l_v_x
    self.l_v_y_0 = l_v_y
    self.l_v_z_0 = l_v_z
    self.sec = g_currentMission.environment.dayTime / 1000

    -- create sensor_msgs/Imu instance
    local imu_msg = sensor_msgs_Imu.new()

    -- populate fields (not using sensor_msgs_Imu:set(..) here as this is much
    -- more readable than a long list of anonymous args)
    imu_msg.header.frame_id = "base_link"
    imu_msg.header.stamp = ros.Time.now()
    -- note the order of the axes here (see earlier comment about FS chirality)
    imu_msg.orientation.x = q_z
    imu_msg.orientation.y = q_x
    imu_msg.orientation.z = q_y
    imu_msg.orientation.w = q_w
    -- TODO get AngularVelocity wrt local vehicle frame
    -- since the farmsim `getAngularVelocity()` can't get body-local angular velocity, we don't set imu_msg.angular_velocity for now

    -- note again the order of the axes
    imu_msg.linear_acceleration.x = acc_z
    imu_msg.linear_acceleration.y = acc_x
    imu_msg.linear_acceleration.z = acc_y

    -- publish the message
    self._pub_imu:publish(imu_msg)

    -- end
    -- end
end

--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- A.5. TF publisher (TODO:add description)
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]
function ModROS:publish_tf()
    self._pub_tf:publish(self.tf_msg)
end

--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- A.6. A command for writing all messages to a named pipe: "rosPubMsg true/false"
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]
-- messages publisher console command
addConsoleCommand("rosPubMsg", "write ros messages to named pipe", "rosPubMsg", ModROS)
function ModROS:rosPubMsg(flag)
    if flag ~= nil and flag ~= "" and flag == "true" then

        if not self._conx:is_connected() then
            print("connecting to named pipe")
            local ret, err = self._conx:connect()
            if ret then
                print("Opened '" .. self._conx:get_uri() .. "'")
            else
                -- if not, print error to console and return
                print(("Could not connect: %s"):format(err))
                print("Possible reasons:")
                print(" - symbolic link was not created")
                print(" - the 'all_in_one_publisher.py' script is not running")
                return
            end
        end

        -- raycastNode initialization
        local vehicle = g_currentMission.controlledVehicle
        -- if the player is not in the vehicle, print error and return
        if not vehicle then
            print("You are not inside any vehicle, come on! Enter 'e' to hop in one next to you!")
            return
        else
            self.instance_veh = VehicleCamera:new(vehicle, ModROS)
            local xml_path = self.instance_veh.vehicle.configFileName
            local xmlFile = loadXMLFile("vehicle", xml_path)
            -- index 0 is outdoor camera; index 1 is indoor camera
            -- local cameraKey = string.format("vehicle.enterable.cameras.camera(%d)", 0)

            --  get the cameraRaycast node 2(on top of ) which is 0 index .raycastNode(0)
            --  get the cameraRaycast node 3 (in the rear) which is 1 index .raycastNode(1)

            local cameraKey = string.format("vehicle.enterable.cameras.camera(%d).raycastNode(0)", 0)
            XMLUtil.checkDeprecatedXMLElements(xmlFile, xml_path, cameraKey .. "#index", "#node") -- FS17 to FS19
            local camIndexStr = getXMLString(xmlFile, cameraKey .. "#node")
            self.instance_veh.cameraNode =
                I3DUtil.indexToObject(
                self.instance_veh.vehicle.components,
                camIndexStr,
                self.instance_veh.vehicle.i3dMappings
            )
            if self.instance_veh.cameraNode == nil then
                print("nil camera")
            -- else
            --     print(instance_veh.cameraNode)
            end
            -- create self.laser_frame_1 attached to raycastNode (x left, y up, z into the page)
            -- and apply a transform to the self.laser_frame_1
            local tran_x, tran_y, tran_z = mod_config.laser_scan.laser_transform.translation.x, mod_config.laser_scan.laser_transform.translation.y, mod_config.laser_scan.laser_transform.translation.z
            local rot_x, rot_y, rot_z = mod_config.laser_scan.laser_transform.rotation.x, mod_config.laser_scan.laser_transform.rotation.y, mod_config.laser_scan.laser_transform.rotation.z
            self.laser_frame_1 = frames.create_attached_node(self.instance_veh.cameraNode, "self.laser_frame_1", tran_x, tran_y, tran_z, rot_x, rot_y, rot_z)
        end

        -- initialisation was successful
        self.doPubMsg = true

    elseif flag == nil or flag == "" or flag == "false" then
        self.doPubMsg = false
        print("stop publishing data, set true, if you want to publish Pose")

        local ret, err = self._conx:disconnect()
        if not ret then
            print(("Could not disconnect: %s"):format(err))
        else
            print("Disconnected")
        end
    end
end

--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- B.1. ros_cmd_teleop subscriber (TODO:add description)
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]
-- a function to load the ROS joystick state from XML file to take over control of manned vehicle in the game
function ModROS:subscribe_ROScontrol_manned_func(dt)
    if g_currentMission.controlledVehicle == nil then
        print("You have left your vehicle, come on! Please hop in one and type the command again!")
        self.doRosControl = false
    elseif g_currentMission.controlledVehicle ~= nil and self.v_ID ~= nil then
        -- retrieve the first 32 chars from the buffer
        -- note: this does not remove them, it simply copies them
        local buf_read = self.buf:read(64)

        -- print to the game console if what we've found in the buffer is different
        -- from what was there the previous iteration
        -- the counter is just there to make sure we don't see the same line twice
        local allowedToDrive = false
        if buf_read ~= self.last_read and buf_read ~= "" then
            self.last_read = buf_read
            local read_str_list = {}
            -- loop over whitespace-separated components
            for read_str in string.gmatch(self.last_read, "%S+") do
                table.insert(read_str_list, read_str)
            end

            self.acc = tonumber(read_str_list[1])
            self.rotatedTime_param = tonumber(read_str_list[2])
            allowedToDrive = read_str_list[3]
        end

        if allowedToDrive == "true" then
            self.allowedToDrive = true
        elseif allowedToDrive == "false" then
            self.allowedToDrive = false
        end

        vehicle_util.ROSControl(self.vehicle, dt, self.acc, self.allowedToDrive, self.rotatedTime_param)
    end
end


--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- B.2. A command for taking over control of a vehicle in the game : "rosControlVehicle true/false"
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]

-- TODO Allow control of vehicles other than the 'active one'. (the console name has already been changed, but the implementation hasn't yet)

--  console command to take over control of manned vehicle in the game
addConsoleCommand("rosControlVehicle", "let ROS control the current vehicle", "rosControlVehicle", ModROS)
function ModROS:rosControlVehicle(flag)
    if flag ~= nil and flag ~= "" and flag == "true" and g_currentMission.controlledVehicle ~= nil then
        self.vehicle = g_currentMission.controlledVehicle
        self.v_ID = g_currentMission.controlledVehicle.components[1].node
        self.doRosControl = true
        print("start ROS teleoperation")
    elseif g_currentMission.controlledVehicle == nil then
        print("you are not inside any vehicle, come on! Enter 'e' to hop in one next to you!")
    elseif flag == nil or flag == "" or flag == "false" then
        self.doRosControl = false
        print("stop ROS teleoperation")

    -- self.acc = 0
    -- self.rotatedTime_param  = 0
    -- self.allowedToDrive = false
    end
end


--[[
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
-- C.1 A command for force-centering the current camera: "forceCenteredCamera true/false"
------------------------------------------------
------------------------------------------------
------------------------------------------------
------------------------------------------------
--]]

-- centering the camera by setting the camera rotX, rotY to original angles
addConsoleCommand("forceCenteredCamera", "force-center the current camera", "forceCenteredCamera", ModROS)
function ModROS:forceCenteredCamera(flag)
    if flag ~= nil and flag ~= "" and flag == "true" then
        if g_currentMission.controlledVehicle ~= nil then
            print("start centering the camera")
            self.doCenterCamera = true
        else
            print("You have left your vehicle, come on! Please hop in one and type the command again!")
        end
    elseif flag == nil or flag == "" or flag == "false" then
        self.doCenterCamera = false
        print("stop centering the camera")
    end
end

addModEventListener(ModROS)
